#!/usr/bin/env perl
# TKT-291. tira.police.outstanding's default output is a Perl array of
# plain strings, and Data::TOON renders an array of plain strings as one
# inline "primitive array" row - every finding comma-joined behind a
# bracketed count and quote marks, so a reader has to parse past that to
# find the first thing. Reproduced live against this project's own board:
# "[18]: \"16 outstanding...\",\"16 to act on:\",\"  VIO-0778 ...\",..." all
# on one visual line.
#
# An array of single-key {line => TEXT} hashes is a different shape to
# TOON: one row per element. That is the whole fix for the squashed output,
# bundled here with the grouped --by-rule view the ticket named as the
# same six lines changing twice otherwise.
#
# The evidence this ticket originally pointed at (a scratchpad file from an
# earlier session, and an entry in t/250's history) no longer exists -
# scratchpad directories are session-scoped. This is a fresh
# implementation with its own coverage, not a restoration.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-24T09:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Grouped', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'GRS', epic_prefix => 'GRE', ticket_prefix => 'GRT',
);

sub run {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => 'police.outstanding', tira => $tira,
                argv => [ '--store', $store, @argv ] );
        };
    };
    return ( $status, $out . $err );
}

$tira->policy_add( project => $root, rule => 'card-unassigned', action => 'log-only' );
$tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );

my $card_a = $tira->create_record( project => $root, type => 'ticket',
    title => 'Breaks card-unassigned', priority => 3, labels => ['standalone'] );
$tira->record_move( author => 'claude', project => $root, ref => $card_a->{ref}, column => 'implement' );
my $card_b = $tira->create_record( project => $root, type => 'ticket',
    title => 'Breaks orphan-card', priority => 3, labels => [] );

$now = '2026-08-24T09:05:00Z';
$tira->police_pass( project => $root, store => $store, world => {} );

# --- each finding on its own line, not squashed onto one --------------------

{
    my ( undef, $said ) = run();

    # Every real find line indented two spaces (the same convention the
    # command already used), each preceded by a newline of its own - not
    # comma-and-quote joined onto the header's line the way a primitive
    # array renders.
    like( $said, qr/\n\s*-\s+line:\s*"[^"]*card-unassigned/,
        'a finding is its own row, not folded onto the row before it' );
    unlike( $said, qr/",\s*"\s*VIO-/,
        'and rows are not comma-joined the way a squashed primitive array would read' );
}

# --- --by-rule groups by rule, each card once --------------------------------

{
    my ( $status, $said ) = run( '--by-rule' );
    is( $status, 0, 'a policed board with --by-rule still exits 0' );
    like( $said, qr/card-unassigned \(1\):/, 'the log-only rule gets its own group header' );
    like( $said, qr/orphan-card \(1\):/,      'and so does the chased rule' );

    # Chased rules sort before log-only ones, matching the default view's
    # own act-on-first ordering.
    my $orphan_at   = index( $said, 'orphan-card (' );
    my $unassigned_at = index( $said, 'card-unassigned (' );
    ok( $orphan_at >= 0 && $unassigned_at >= 0 && $orphan_at < $unassigned_at,
        'and the group somebody should act on sorts before the one merely recorded' );
}

# --- each card appears once per rule even if a second policy for the same --
# rule also matched it ------------------------------------------------------

{
    $tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder', ref => $card_b->{ref} );
    $now = '2026-08-24T09:06:00Z';
    $tira->police_pass( project => $root, store => $store, world => {} );
    my ( undef, $said ) = run('--by-rule');
    my $count = () = $said =~ /\Q$card_b->{ref}\E/g;
    is( $count, 1, "the same card under the same rule is listed once, not once per matching policy" );
}

# --- -o json is unaffected: still the bare list the clear-violations loop --
# pipes -----------------------------------------------------------------------

{
    my ( undef, $plain_json )  = run( '-o', 'json' );
    my ( undef, $grouped_json ) = run( '--by-rule', '-o', 'json' );
    is( $grouped_json, $plain_json,
        '--by-rule changes nothing about -o json - only the default summary' );
}

done_testing;

__END__

=head1 NAME

369-a-list-that-reads-as-a-list.t - each outstanding finding on its own line

=head1 DESCRIPTION

C<tira.police.outstanding>'s default output used to be a flat array of
strings, which Data::TOON renders as one inline row - every finding
comma-joined behind a bracketed count and quote marks. Returning an array
of single-key C<{line =E<gt> TEXT}> hashes instead gives one row per
finding, the way every other list-shaped answer in this project already
reads.

C<--by-rule> groups the same findings by rule instead of by chased/recorded,
each card listed once per rule even when two policies for the same rule
matched it, with the rules somebody should act on sorting before the ones
the board only logs. C<-o json> is unaffected either way - the bare list the
clear-violations instruction pipes.

=cut
