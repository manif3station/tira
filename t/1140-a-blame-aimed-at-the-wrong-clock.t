#!/usr/bin/env perl
# TKT-1094. police_freshness reads two timestamps through _epoch_of_datetime,
# each labeled distinctly ('Pass' for the stored last_pass stamp, 'Clock' for
# $self->{clock}->()'s own reading) - but both calls are wrapped in eval, and
# the die's label is discarded either way. $age stays undef whichever side
# failed, so lib/Tira/CLI/Police.pm's UNREADABLE message (fired whenever
# age_seconds is undef but taken_at is defined) always reads "last pass
# <value> - UNREADABLE", blaming the stored stamp even when it was actually
# the clock reading that could not be parsed.
#
# Unreachable in real production - $self->{clock}->() always emits a valid
# ISO 8601 string there - but reachable via an injected test clock, which is
# exactly how this file reproduces it.
#
# WRITTEN RED.

use strict;
use warnings;

use Cpanel::JSON::XS ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp   = tempdir( CLEANUP => 1 );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

# A working clock records a real, readable last_pass first.
my $good_now = '2026-09-21T00:00:00+0100';
my $tira     = Tira->new( clock => sub { $good_now } );
$tira->project_new(
    name => 'Freshness', dir => $root, members => ['claude'],
    columns    => ['backlog, implement, done'],
    sow_prefix => 'FRS', epic_prefix => 'FRE', ticket_prefix => 'FRT',
);
$tira->policy_add( project => $root, rule => 'answer-ok-not-folded', age => '1m', action => 'bridge-reminder' );
$tira->police_pass( project => $root, store => $store, world => {} );

my $direct = $tira->police_freshness( store => $store );
ok( defined $direct->{age_seconds}, 'sanity: a working clock against a real pass reads a real age' );
is( $direct->{unreadable}, undef, 'and unreadable is undef when nothing failed to parse' );

# --- the stored stamp is fine; the CLOCK reading it against is what breaks ---

my $broken_clock = Tira->new( clock => sub { 'not-a-timestamp' } );

my $answer = $broken_clock->police_freshness( store => $store );
ok( !defined $answer->{age_seconds}, 'a broken clock still leaves age_seconds undefined, same as today' );
ok( $answer->{stale}, 'and still reports stale - the judgement itself does not change' );

# Codex review: proving the CLI message names the clock is not the same as
# proving the underlying field it reads is actually correct - a message
# assembled from a wrong or absent field could still happen to say "clock"
# by coincidence of prose, not by reading real data. Checked directly.
is( $answer->{unreadable}, 'clock', 'and the underlying field itself says clock, not just the message built from it' );

sub cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => 'police.freshness', tira => $broken_clock,
            argv => [ '--store', $store, @argv ] );
    };
    return ( $status, $out . $err );
}

my ( undef, $human ) = cli();
like( $human, qr/UNREADABLE/, 'still says UNREADABLE - the message is not simply removed' );
like( $human, qr/clock/i,
    'and names the CLOCK as the side that failed, not the stored pass time - the actual cause, not a guess' );
unlike( $human, qr/last pass\b.*not-a-timestamp/i,
    "and does not print the stored pass time as though IT were the garbled value - it wasn't" );

# --- the real-production path (a genuinely unreadable stored stamp) is unchanged ---

{
    my $ledger = File::Spec->catfile( $store, 'violations.json' );
    open my $in, '<', $ledger or die "$ledger: $!";
    my $held = do { local $/; <$in> };
    close $in;
    ( my $corrupt = $held ) =~ s/"last_pass"\s*:\s*"[^"]*"/"last_pass":"not-a-timestamp"/;
    isnt( $corrupt, $held, 'the ledger has a last_pass to corrupt' );
    open my $out2, '>', $ledger or die "$ledger: $!";
    print {$out2} $corrupt;
    close $out2;

    my $working_clock = Tira->new( clock => sub { $good_now } );
    my ( undef, $stamp_human ) = do {
        local $ENV{TIRA_HOME} = $root;
        my ( $out, $err ) = ( '', '' );
        open my $so, '>', \$out or die $!;
        open my $se, '>', \$err or die $!;
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run( command => 'police.freshness', tira => $working_clock,
            argv => [ '--store', $store ] );
        ( undef, $out . $err );
    };
    like( $stamp_human, qr/UNREADABLE/, 'a genuinely unreadable stored stamp still says UNREADABLE' );
    unlike( $stamp_human, qr/clock/i,
        'and does NOT blame the clock when the clock itself is fine - only the actual failing side is named' );

    my $stamp_answer = $working_clock->police_freshness( store => $store );
    is( $stamp_answer->{unreadable}, 'pass',
        'and the underlying field says pass, matching the real cause, not just the prose' );

    my ( undef, $stamp_json ) = do {
        local $ENV{TIRA_HOME} = $root;
        my ( $out, $err ) = ( '', '' );
        open my $so, '>', \$out or die $!;
        open my $se, '>', \$err or die $!;
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run( command => 'police.freshness', tira => $working_clock,
            argv => [ '--store', $store, '-o', 'json' ] );
        ( undef, $out );
    };
    my $decoded = eval { Cpanel::JSON::XS::decode_json($stamp_json) };
    is( $decoded->{unreadable}, 'pass', 'and -o json carries the same field, not just the human wrapper' );

    open my $back, '>', $ledger or die "$ledger: $!";
    print {$back} $held;
    close $back;
}

done_testing;

__END__

=head1 NAME

1140-a-blame-aimed-at-the-wrong-clock.t - police_freshness's UNREADABLE
message names the side that actually failed

=head1 DESCRIPTION

TKT-1094. C<police_freshness> reads two timestamps through
C<_epoch_of_datetime>, distinctly labeled ('Pass' vs 'Clock') at the call
site - but both calls are wrapped in C<eval>, discarding the label either
way, so C<age_seconds> stays undefined whichever side failed to parse. The
CLI's UNREADABLE message assumed the stored pass stamp was always the
culprit, which is true in real production (the clock always emits a valid
ISO 8601 string there) but not true against an injected test clock that
returns garbage - exactly the scenario this file reproduces.

Proves the message now names the clock specifically when that is the side
that failed, without changing the judgement (still stale, still no
invented age) or the real-production path (a genuinely unreadable stored
stamp still reads UNREADABLE, and is not mistakenly blamed on the clock).

=cut
