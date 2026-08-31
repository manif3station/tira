#!/usr/bin/env perl
# TKT-678, corrected scope (Q-100, answered by the owner 2026-08-31): a
# backward move resets every required item tagged with a column between the
# destination and the origin, inclusive on both ends (TKT-455/TKT-525) - a
# whole-column reset. Reported from zen-framework: a Codex finding about a
# markdown fence invalidated "assign yourself to the card", "set the start
# date", "link the related tasks" and "set the reporter" on the SAME column
# as the real build/review gates, because the reset cannot tell an
# administrative bookkeeping item from a gate on the actual work - it only
# knows which COLUMN an item belongs to, not what kind of item it is.
#
# Fixed with a per-item declared flag: tira.column.update
# --administrative-action TEXT names specific items (by their exact text,
# matched the same way --required-action/--entry-required-action already
# dedupe) that a backward move must never reset, regardless of whether their
# column falls inside the reset range. TKT-455/TKT-525's own column-range
# design is otherwise completely unchanged - a build gate in that same
# range still resets exactly as before.

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
    name => 'Scoped Reset', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'document', 'verify' ],
    sow_prefix => 'SRS', epic_prefix => 'SRE', ticket_prefix => 'SRT',
);

# verify carries two items sharing a column: one administrative bookkeeping
# item and one real build gate - the exact shape of the reporter's complaint.
$tira->column_update(
    project => $root, type => 'ticket', name => 'verify',
    required_action => [ 'assign yourself to the card', 'run the full suite' ],
    administrative_action => ['assign yourself to the card'],
);

sub cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME}   = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    return Tira::CLI->run( command => 'record.move', type => 'ticket', argv => \@argv );
}

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Round trip' );

sub status_of {
    my ($item_name) = @_;
    my ($item) = grep { $_->{item} eq $item_name }
      @{ $tira->required_item_list( project => $root, ref => $card->{ref} ) };
    return $item->{status};
}

sub mark_done {
    my ($item_name) = @_;
    my ($item) = grep { $_->{item} eq $item_name }
      @{ $tira->required_item_list( project => $root, ref => $card->{ref} ) };
    $tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref}, id => $item->{id},
        status => 'done', command => ["did: $item_name"], proof => ["done: $item_name"] );
}

cli( '--ref', $card->{ref}, '--column', 'document' );
cli( '--ref', $card->{ref}, '--column', 'verify' );
mark_done('assign yourself to the card');
mark_done('run the full suite');

is( status_of('assign yourself to the card'), 'done', 'both items are done before the backward move' );
is( status_of('run the full suite'), 'done', 'both items are done before the backward move' );

# --- the fix: return to document, one column back -------------------------

cli( '--ref', $card->{ref}, '--column', 'document' );

is( status_of('assign yourself to the card'), 'done',
    'the administrative item survives the backward move - its truth cannot have changed' );
is( status_of('run the full suite'), 'pending',
    'the real build gate, same column, resets exactly as TKT-455/TKT-525 already decided' );

# --- control: an administrative item at the very destination also survives,
# even on a return all the way to backlog (TKT-525's own accepted case) ----

$tira->column_update(
    project => $root, type => 'ticket', name => 'backlog',
    required_action => ['set the reporter'],
    administrative_action => ['set the reporter'],
);
my $card2 = $tira->create_record( project => $root, type => 'ticket', title => 'Round trip to backlog' );

# Seeded directly rather than via natural population - backlog is index 0,
# so nothing ever moves "forward into" it to trigger its own exit-action
# template the way every other column gets populated; only a backward
# landing does that (TKT-455/TKT-525), which is exactly the case under test.
$tira->required_item_add( author => 'claude', project => $root, ref => $card2->{ref},
    type => 'ticket', column => 'backlog', item => 'set the reporter', status => 'done',
    source => 'required-action' );

cli( '--ref', $card2->{ref}, '--column', 'document' );
cli( '--ref', $card2->{ref}, '--column', 'backlog' );
my ($reporter_item) = grep { $_->{item} eq 'set the reporter' }
  @{ $tira->required_item_list( project => $root, ref => $card2->{ref} ) };
is( $reporter_item->{status}, 'done',
    'an administrative item survives even a return all the way to backlog' );

done_testing;

__END__

=head1 NAME

t/457-a-reset-that-cannot-tell-the-difference.t - a backward move leaves
declared administrative items alone

=head1 DESCRIPTION

TKT-678 (corrected scope, Q-100): the backward-move reset
(C<_apply_column_required_actions>) reset every required item tagged with
a column in range, unable to tell an administrative bookkeeping item
("assign yourself", "set the reporter") from a real build/review gate
sharing the same column - so a Codex finding about a markdown fence
invalidated both, re-proving work whose truth could not possibly have
changed.

Fixed with C<tira.column.update --administrative-action TEXT>: a declared,
per-item exemption from the backward-move reset, matched by exact text the
same way C<--required-action>/C<--entry-required-action> already dedupe.
TKT-455/TKT-525's own column-range design - including resetting the
destination column, and resetting all the way back to backlog - is
otherwise unchanged; a build gate in the same range still resets exactly
as before.

=cut
