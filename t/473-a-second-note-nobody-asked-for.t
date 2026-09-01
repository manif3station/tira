#!/usr/bin/env perl
# TKT-806. tasklist_add created a brand-new item on every call with zero
# deduplication - no check against existing pending/working items sharing
# the same --ref and session. Hit three separate times in one session
# (TKT-675, TKT-788, TKT-793): each card already had a pending/working
# tasklist item from an earlier pickup, and adding a fresh "pick this up"
# item for the same card created a second, indistinguishable entry,
# discovered only by manually listing and cross-checking.
#
# Fixed as a soft signal, not a hard refusal - tasklist's own "sticky-note,
# no gates" philosophy: a caller may legitimately want two distinct tasks
# on the same card, so the new item is still created, but the returned
# entry names the existing pending/working item it may be duplicating.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-01T12:00:00+0100' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Duped tasks', dir => $root, members => ['ada'],
    columns => ['backlog, doing, done'],
    sow_prefix => 'DTS', epic_prefix => 'DTE', ticket_prefix => 'DTT',
);

my $card = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'A card' );

my $first = $tira->tasklist_add( project => $root, text => 'Pick this up', refs => [ $card->{ref} ] );
ok( !exists $first->{possible_duplicate}, 'the first item for a card carries no duplicate warning - nothing existed before it' );

my $second = $tira->tasklist_add( project => $root, text => 'Pick this up again', refs => [ $card->{ref} ] );
ok( exists $second->{possible_duplicate}, 'a second pending item for the same card surfaces the existing one - the fix' );
is( $second->{possible_duplicate}{id}, $first->{id}, 'naming the right id' );
is( $second->{possible_duplicate}{text}, 'Pick this up', 'and the right text' );

my $listed = $tira->tasklist_list( project => $root );
is( scalar @{$listed}, 2, 'the new item is still created - a soft signal, not a hard refusal' );

my ($stored_second) = grep { $_->{id} eq $second->{id} } @{$listed};
ok( !exists $stored_second->{possible_duplicate},
    'possible_duplicate is computed on the add response only, never written to the store - '
      . 'a stored value would go stale the moment the item it names changed status. Codex review' );

# --- a done item does not count as still-owed, so no warning fires --------

$tira->tasklist_update( project => $root, id => $first->{id}, status => 'done' );
$tira->tasklist_update( project => $root, id => $second->{id}, status => 'done' );
my $third = $tira->tasklist_add( project => $root, text => 'Pick this up once more', refs => [ $card->{ref} ] );
ok( !exists $third->{possible_duplicate},
    'once every prior item for this card is DONE - not "still owed" - a fresh pickup carries no warning' );

# --- a different card's item never triggers the warning --------------------

my $other_card = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'A different card' );
my $unrelated = $tira->tasklist_add( project => $root, text => 'Pick this up too', refs => [ $other_card->{ref} ] );
ok( !exists $unrelated->{possible_duplicate}, 'a different card\'s pending item never counts as a duplicate of this one' );

# --- a genuinely unlinked item (no refs at all) is not compared either -----

my $unlinked_a = $tira->tasklist_add( project => $root, text => 'General note one' );
my $unlinked_b = $tira->tasklist_add( project => $root, text => 'General note two' );
ok( !exists $unlinked_b->{possible_duplicate}, 'items with no refs at all are never flagged against each other' );

done_testing;

__END__

=head1 NAME

t/473-a-second-note-nobody-asked-for.t - tasklist.add surfaces an
existing pending/working item for the same card instead of silently
duplicating it

=head1 DESCRIPTION

C<tasklist_add> had zero deduplication: every call created a brand-new
item, even when a pending or working item already existed for the same
C<--ref> and session. Hit three times in one real session, each time
discovered only by manually cross-checking the shared list by hand.

Fixed as a soft signal rather than a hard refusal, matching tasklist's
own "sticky-note, no gates" design: the new item is still created, but
its returned entry carries a C<possible_duplicate> key (the existing
item's id and text) whenever a pending or working item already shares
one of the same refs. A done item, an unrelated card, or an item with
no refs at all never triggers it. TKT-806.

=cut
