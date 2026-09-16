#!/usr/bin/env perl
# TKT-824. TKT-806 added a possible_duplicate soft signal to tasklist_add,
# firing when --ref names a card that already has a pending/working item.
# The browser dashboard's tasklist UI cannot ever trigger or see this
# signal, structurally: its quick-add flow posts to /tasklist/add with
# text only, no ref, and its ref-attachment flow is a SEPARATE call
# afterward (/tasklist/task/ref/link) that never ran the check at all - a
# person working entirely through the browser got none of TKT-806's
# protection.
#
# tasklist_task_ref_link now runs the identical check
# (_tasklist_possible_duplicate, the same helper tasklist_add itself
# calls, extracted so neither copy can drift from the other) against every
# ref the item carries once linked, and surfaces the same possible_duplicate
# field tasklist_add's own response already carries.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-16T04:10:00+0100' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Linked tasks', dir => $root, members => ['ada'],
    columns => ['backlog, doing, done'],
    sow_prefix => 'LKS', epic_prefix => 'LKE', ticket_prefix => 'LKT',
);

my $card = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'A card' );

# The existing pending item is created WITHOUT a ref at add-time, exactly
# the browser's own quick-add flow (text only) - then linked separately,
# the browser's own two-step shape this ticket is about.
my $first = $tira->tasklist_add( project => $root, text => 'Pick this up' );
ok( !exists $first->{possible_duplicate}, 'no ref at add-time, nothing to compare against yet' );
my $linked_first = $tira->tasklist_task_ref_link( project => $root, id => $first->{id}, refs => [ $card->{ref} ] );
ok( !exists $linked_first->{possible_duplicate}, 'the first link for this card carries no duplicate warning - nothing existed before it' );

# A second task, also added without a ref, then linked to the SAME card -
# the exact scenario TKT-824 was filed over: a person using only the
# browser's ref-link action, never touching tasklist_add's own --ref flag.
my $second = $tira->tasklist_add( project => $root, text => 'Pick this up again' );
my $linked_second = $tira->tasklist_task_ref_link( project => $root, id => $second->{id}, refs => [ $card->{ref} ] );
ok( exists $linked_second->{possible_duplicate},
    'linking a second task to a card that already has a pending link surfaces the signal - the fix' );
is( $linked_second->{possible_duplicate}{id}, $first->{id}, 'naming the right id' );
is( $linked_second->{possible_duplicate}{text}, 'Pick this up', 'and the right text' );

my $listed = $tira->tasklist_list( project => $root );
my ($stored_second) = grep { $_->{id} eq $second->{id} } @{$listed};
ok( !exists $stored_second->{possible_duplicate},
    'possible_duplicate is computed on the link response only, never written to the store - '
      . 'the same discipline tasklist_add already follows (TKT-806, Codex review)' );

# A done item is not "still owed" and does not count - matching
# tasklist_add's own rule exactly. Both existing items marked done, or the
# still-pending $second would legitimately fire the warning again on its
# own account, muddying what this assertion is actually about.
$tira->tasklist_update( project => $root, id => $first->{id}, status => 2 );
$tira->tasklist_update( project => $root, id => $second->{id}, status => 2 );
my $third = $tira->tasklist_add( project => $root, text => 'Third pickup' );
my $linked_third = $tira->tasklist_task_ref_link( project => $root, id => $third->{id}, refs => [ $card->{ref} ] );
ok( !exists $linked_third->{possible_duplicate},
    'done items do not count as duplicates - both earlier items are done, so this link is unwarned' );

# --- checked against the refs THIS CALL requested, not every ref the item
#     now carries (Codex review) ------------------------------------------
#
# A naive version compared against $entry->{refs} - every ref the item has
# ever accumulated - which would report card A's own pre-existing pending
# item as a "duplicate" the moment a wholly unrelated ref B is linked to a
# fresh item that never claimed A at all, and again on a harmless re-link
# of a ref already present.

{
    my $card_a = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'Card A' );
    my $card_b = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'Unrelated card B' );

    # A genuinely pre-existing pending item for card A - the fixture the
    # over-warning bug needs to actually manifest against.
    my $existing_a = $tira->tasklist_add( project => $root, text => 'Existing pickup for A' );
    $tira->tasklist_task_ref_link( project => $root, id => $existing_a->{id}, refs => [ $card_a->{ref} ] );

    my $fourth = $tira->tasklist_add( project => $root, text => 'Fourth pickup' );
    my $linked_a = $tira->tasklist_task_ref_link( project => $root, id => $fourth->{id}, refs => [ $card_a->{ref} ] );
    ok( exists $linked_a->{possible_duplicate},
        'linking card A to a second item correctly surfaces the real, existing duplicate' );

    # $fourth now carries card A from the link just made. Linking it to an
    # UNRELATED card B must judge only B - not re-report the same A
    # conflict on every later, unrelated link this item ever makes.
    my $linked_b = $tira->tasklist_task_ref_link( project => $root, id => $fourth->{id}, refs => [ $card_b->{ref} ] );
    ok( !exists $linked_b->{possible_duplicate},
        'linking an UNRELATED second ref does not re-report the duplicate caused by the first, already-linked ref' );

    my $relinked_a = $tira->tasklist_task_ref_link( project => $root, id => $fourth->{id}, refs => [ $card_a->{ref} ] );
    ok( exists $relinked_a->{possible_duplicate},
        're-linking a ref this item already carries still judges that ref honestly - the conflict with the OTHER '
          . 'item is still real, this is not the no-op case' );
}

done_testing;

__END__

=head1 NAME

1110-a-link-that-never-checked.t - the browser's ref-link action gets TKT-806's duplicate signal too

=head1 WHY

TKT-824: the browser dashboard's tasklist UI adds a task with text only,
then links a ref through a SEPARATE call that never ran tasklist_add's own
possible_duplicate check - a person working entirely through the browser
got none of TKT-806's protection. tasklist_task_ref_link now runs the
identical check, via the same extracted helper tasklist_add itself calls.

=head1 WHAT IS ASSERTED

Linking a ref to a task, when another pending/working task already
carries the same ref, surfaces the same possible_duplicate field
tasklist_add's own response carries - naming the existing item's id and
text, computed on the response only (never written to the store), and
silent when the existing item is done.

=cut
