#!/usr/bin/env perl
# TKT-846. checklist_add and checklist_update validate --status
# case-insensitively against pending, done and 'to do' (TKT-668, Q-099).
# The validation was added without migrating what was already stored: 8
# items on EPC-007 carry the legacy spelling "todo" (no space), which is
# not in the accepted set. An agent that reads one of those items and
# writes the same value back - the ordinary round-trip every other status
# already supports - is refused for a value the board itself produced.
#
# Decision recorded on the card (CHK-002): widen the accepted set to
# include "todo", rather than migrate the 8 stored items - the smaller,
# lower-risk change.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-16T06:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Legacy Status', dir => $root, members => ['ada'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'LSS', epic_prefix => 'LSE', ticket_prefix => 'LST',
);

my $card = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'A card' );

# --- every stored spelling round-trips, todo included ----------------------
#
# A status of 'done' requires a --command/--proof pair (TKT-958) - unrelated
# to this ticket, but every case here has to satisfy it to reach the
# vocabulary check at all.
for my $spelling (qw(pending done), 'To Do', 'todo') {
    my %done_args = lc($spelling) eq 'done' ? ( command => ['did it'], proof => ['done'] ) : ();
    my $item = $tira->checklist_add( project => $root, author => 'ada', ref => $card->{ref},
        item => "item for $spelling", status => $spelling, %done_args );
    ok( $item, "checklist_add accepts stored spelling '$spelling'" );

    my $updated = $tira->checklist_update( project => $root, author => 'ada', ref => $card->{ref},
        id => $item->{id}, status => $spelling, %done_args );
    is( $updated->{status}, $spelling, "checklist_update writes '$spelling' back unchanged - the round-trip" );
}

# --- a genuine misspelling is still refused - TKT-668 is not undone --------
for my $bad ( 'Donee', 'in progress' ) {
    eval {
        $tira->checklist_add( project => $root, author => 'ada', ref => $card->{ref},
            item => 'bad status', status => $bad );
    };
    like( $@, qr/Unknown checklist status/, "checklist_add still refuses a genuine misspelling: '$bad'" );
}

# --- checklist_list's --status filter understands todo too -----------------
#
# Exactly one, not "at least one" - a filter that quietly ignored --status
# and returned every item would satisfy ">= 1" without ever having filtered
# anything (Codex review).
my $todo_items = $tira->checklist_list( project => $root, ref => $card->{ref}, status => 'todo' );
is( scalar( @{$todo_items} ), 1, "checklist_list --status todo finds exactly the one item stored as 'todo'" );
is( lc( $todo_items->[0]{status} ), 'todo', 'and it really is the todo-spelled one' );

done_testing;

__END__

=head1 NAME

1112-a-status-the-board-itself-handed-out.t - checklist status vocabulary agrees between read and write

=head1 WHY

TKT-846: 8 items on EPC-007 carry the legacy spelling "todo", which
checklist_add/checklist_update's own validation (TKT-668) refuses. An
agent that reads a stored status and writes it back unchanged is refused
for a value the board itself produced.

=head1 WHAT IS ASSERTED

Every stored spelling (pending, done, To Do, todo) round-trips through
both checklist_add and checklist_update. A genuine misspelling (Donee, in
progress) is still refused. checklist_list's --status filter also accepts
todo.

=cut
