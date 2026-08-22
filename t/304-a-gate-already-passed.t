#!/usr/bin/env perl
# TKT-426's chain check refuses a forward move that skips ahead, with no
# accommodation for a card whose intermediate stages already have a passing
# gate recorded - reported live from a real board: a fully-gated,
# CI-still-pending ticket parked back at backlog to respect a single-agent
# WIP limit, wanting to return directly to its terminal column once CI
# concludes, with every intervening gate already logged pass. The only way
# to reach the terminal column was a rapid multi-hop walk through columns
# the card never substantively occupied - a column-history timeline that
# lies about where the work actually happened.
#
# Settled by the owner (Q-053, TKT-429): the convention is a naming one, not
# a new mapping - a gate named exactly like the column it stands in for,
# recorded pass, is what lets a move skip past that column.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );

my $tira = Tira->new;
$tira->project_new(
    name => 'Gated', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'doc', 'code', 'done' ],
    sow_prefix => 'GTS', epic_prefix => 'GTE', ticket_prefix => 'GTT',
);

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    local $ENV{TIRA_AUTHOR} = "claude";
    my $status = Tira::CLI->run( command => $command, type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

# --- without any gate recorded, a skip still refuses exactly as before -----
my $ungated = $tira->create_record( project => $root, type => 'ticket', title => 'No gates recorded' );
my ( $status, $out, $err ) = cli( 'record.move', '--ref', $ungated->{ref}, '--column', 'code' );
isnt( $status, 0, 'a skip with no gates recorded still refuses' );
like( $err, qr/planning/, 'naming the correct next column' );

# --- a card with only ONE of the two skipped columns gated still refuses --
my $partial = $tira->create_record( project => $root, type => 'ticket', title => 'Only one gate' );
$tira->gate_add( author => 'claude', project => $root, ref => $partial->{ref}, gate => 'planning', result => 'pass', details => 'Done' );
( $status, $out, $err ) = cli( 'record.move', '--ref', $partial->{ref}, '--column', 'code' );
isnt( $status, 0, 'one gated column out of two skipped is not enough' );

# --- a card with BOTH skipped columns gated pass can skip straight there ---
my $gated = $tira->create_record( project => $root, type => 'ticket', title => 'Fully gated' );
$tira->gate_add( author => 'claude', project => $root, ref => $gated->{ref}, gate => 'planning', result => 'pass', details => 'Done' );
$tira->gate_add( author => 'claude', project => $root, ref => $gated->{ref}, gate => 'doc', result => 'pass', details => 'Done' );
( $status, $out, $err ) = cli( 'record.move', '--ref', $gated->{ref}, '--column', 'code' );
is( $status, 0, 'both skipped columns gated pass lets the move skip straight there' ) or diag($err);
is( $tira->record_show( project => $root, ref => $gated->{ref} )->{column}, 'code', 'and it actually landed there' );

# --- a FAILED gate does not count, even with the right name ----------------
my $failed = $tira->create_record( project => $root, type => 'ticket', title => 'A failed gate' );
$tira->gate_add( author => 'claude', project => $root, ref => $failed->{ref}, gate => 'planning', result => 'pass', details => 'Done' );
$tira->gate_add( author => 'claude', project => $root, ref => $failed->{ref}, gate => 'doc', result => 'fail', details => 'Broke' );
( $status, $out, $err ) = cli( 'record.move', '--ref', $failed->{ref}, '--column', 'code' );
isnt( $status, 0, 'a gate recorded fail, not pass, does not count' );

# --- all the way to done, three columns skipped, all three gated -----------
my $full = $tira->create_record( project => $root, type => 'ticket', title => 'Skip everything' );
$tira->gate_add( author => 'claude', project => $root, ref => $full->{ref}, gate => 'planning', result => 'pass', details => 'Done' );
$tira->gate_add( author => 'claude', project => $root, ref => $full->{ref}, gate => 'doc', result => 'pass', details => 'Done' );
$tira->gate_add( author => 'claude', project => $root, ref => $full->{ref}, gate => 'code', result => 'pass', details => 'Done' );
( $status, $out, $err ) = cli( 'record.move', '--ref', $full->{ref}, '--column', 'done' );
is( $status, 0, 'every intervening column gated pass skips all the way to the terminal column' ) or diag($err);

done_testing;

__END__

=head1 NAME

304-a-gate-already-passed.t - a skip is allowed when every skipped column was already gated pass

=head1 DESCRIPTION

Covers TKT-429: a forward move that would otherwise be refused for skipping
ahead succeeds if every column strictly between the origin and the
destination already carries a gate_passing_log entry named exactly like
that column, with result pass. A missing gate, a wrongly-named one, or one
recorded fail all still refuse.

=cut
