#!/usr/bin/env perl
# TKT-845. checklist-idle reports any card whose checklist has not moved
# within the policy age, unless the card is in an ending column. A standing
# container card (EPC-007 collecting bridge-reported defects for the length
# of the programme, SOW-004 spanning it) is neither ending nor stalled - it
# always carries open items and is worked in bursts. Measured 2026-09-02:
# 108 reports on EPC-007 (VIO-0772) and 124 on SOW-004 (VIO-0777), both
# CRITICAL-toned and true about elapsed time while naming an action ("tick
# something") that is not the action either card needs.
#
# The mechanism: a card carries a "standing" label (case-insensitively,
# matching every other label check this file already makes) - visible on
# the card itself, not held in policy configuration, so a reader of
# ticket.show sees why the card is exempt. checklist-idle skips a record
# with that label; every other card is reported exactly as it is today.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-09-16T10:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Standing', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'STS', epic_prefix => 'STE', ticket_prefix => 'STT',
);
my $store = File::Spec->catdir( $tmp, 'police-store' );

$tira->policy_add( project => $root, rule => 'checklist-idle',
    column => 'implement', age => '10m', action => 'bridge-reminder' );

sub idle_findings {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq 'checklist-idle' } @{ $pass->{violations} } ];
}

# --- a standing card is held, even with an open checklist and no movement --
my $standing = $tira->create_record(
    project => $root, type => 'epic', title => 'Bridge-reported defects, ongoing',
    labels => ['standing'] );
$tira->record_move( author => 'claude', project => $root, ref => $standing->{ref}, column => 'implement' );
$tira->checklist_add( author => 'claude', project => $root, ref => $standing->{ref}, item => 'still open', status => 'pending' );

$now = '2026-09-16T10:20:00Z';
my @standing_found = grep { $_->{ref} eq $standing->{ref} } @{ idle_findings() };
is( scalar @standing_found, 0, 'a standing card with an idle checklist is not reported' );

# --- the label is case-insensitive, matching every other label check here -
my $shouting = $tira->create_record(
    project => $root, type => 'epic', title => 'Also ongoing',
    labels => ['STANDING'] );
$tira->record_move( author => 'claude', project => $root, ref => $shouting->{ref}, column => 'implement' );
$tira->checklist_add( author => 'claude', project => $root, ref => $shouting->{ref}, item => 'still open', status => 'pending' );

my @shouting_found = grep { $_->{ref} eq $shouting->{ref} } @{ idle_findings() };
is( scalar @shouting_found, 0, 'the label is matched case-insensitively' );

# --- an ordinary card is reported exactly as it is today - the hold does --
#     not leak onto cards that never claimed it -----------------------------
$now = '2026-09-16T11:00:00Z';
my $ordinary = $tira->create_record( project => $root, type => 'ticket', title => 'A normal ticket' );
$tira->record_move( author => 'claude', project => $root, ref => $ordinary->{ref}, column => 'implement' );
$tira->checklist_add( author => 'claude', project => $root, ref => $ordinary->{ref}, item => 'not yet', status => 'pending' );

$now = '2026-09-16T11:20:00Z';
my @ordinary_found = grep { $_->{ref} eq $ordinary->{ref} } @{ idle_findings() };
is( scalar @ordinary_found, 1, 'an ordinary card without the label is still reported - the hold does not leak' );
like( $ordinary_found[0]{detail}, qr/no checklist movement/, 'with its existing message, unchanged' );

# --- an unrelated label does not accidentally grant the hold ---------------
$now = '2026-09-16T12:00:00Z';
my $other_label = $tira->create_record(
    project => $root, type => 'ticket', title => 'Carries an unrelated label',
    labels => ['urgent'] );
$tira->record_move( author => 'claude', project => $root, ref => $other_label->{ref}, column => 'implement' );
$tira->checklist_add( author => 'claude', project => $root, ref => $other_label->{ref}, item => 'not yet', status => 'pending' );

$now = '2026-09-16T12:20:00Z';
my @other_found = grep { $_->{ref} eq $other_label->{ref} } @{ idle_findings() };
is( scalar @other_found, 1, 'a card with a different label is not accidentally held' );

# --- an unlabelled EPIC is still reported - both held cases above are ------
#     epics, so without this the fix could be exempting every epic/container
#     rather than only a "standing"-labelled record, and this file would
#     never catch it (Codex review) --------------------------------------
$now = '2026-09-16T13:00:00Z';
my $unlabelled_epic = $tira->create_record( project => $root, type => 'epic', title => 'An epic with no label at all' );
$tira->record_move( author => 'claude', project => $root, ref => $unlabelled_epic->{ref}, column => 'implement' );
$tira->checklist_add( author => 'claude', project => $root, ref => $unlabelled_epic->{ref}, item => 'not yet', status => 'pending' );

$now = '2026-09-16T13:20:00Z';
my @unlabelled_epic_found = grep { $_->{ref} eq $unlabelled_epic->{ref} } @{ idle_findings() };
is( scalar @unlabelled_epic_found, 1,
    'an epic without the "standing" label is still reported - the hold is about the label, not the type' );

done_testing;

__END__

=head1 NAME

1111-a-card-that-was-never-going-to-finish.t - checklist-idle holds standing cards, not ordinary ones

=head1 WHY

TKT-845: checklist-idle reported EPC-007 and SOW-004 108 and 124 times
respectively, both CRITICAL-toned and true about elapsed time while naming
an action ("tick something") that is not the action either card needed.
Clearing each report bought silence until the age window passed again - a
treadmill, not a fix.

=head1 WHAT IS ASSERTED

A record carrying a "standing" label (case-insensitive) is skipped entirely
by checklist-idle, however long its checklist has stood still. A record
without that label is reported exactly as it is today - the hold does not
leak onto ordinary cards, nor onto a card carrying a different, unrelated
label.

=cut
