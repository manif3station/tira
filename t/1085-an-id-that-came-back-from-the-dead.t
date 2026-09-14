#!/usr/bin/env perl
# TKT-642. required_item_add and checklist_add mint the next id from
# `scalar(@list) + 1` - correct only while nothing ever shortens the list.
# Removing an item by hand from the record (there is no removal command
# today, but the browser dialog already removes checklist entries in its
# UI sense, and nothing stops a hand-edit) and adding another can collide
# with an id still on the list, so a proof, refusal, or
# required-action.update call quoting that id now points at the wrong
# item - a history that was never its own.
#
# conversation_add already scans existing entries for the highest number
# rather than counting, and this proves required_item_add and
# checklist_add should do the same - by simulating a hand-removal (splice
# on the record, replaced via _replace_record - the same technique other
# tests in this suite already use to reach past the public API) and then
# adding a fresh item. A max-scan closes the collision case but not the
# one it structurally cannot: removing the currently-highest item and
# adding again reissues that exact number, the same known limit
# conversation_add already carried - pinned here explicitly (not left for
# a reader to assume is fixed too) rather than closed, since closing it
# needs a persisted counter and that is out of this ticket's scope.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'ids' );
my $tira = Tira->new( clock => sub { '2026-09-14T00:00:00Z' } );
$tira->create_project( name => 'Ids', dir => $root );

# --- required_item_add: a removed item does not collide with a surviving one ---

{
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Required items' );
    for my $item (qw(First Second Third)) {
        $tira->required_item_add( author => 'claude',
            project => $root, ref => $record->{ref}, item => $item, status => 'pending',
        );
    }
    my $shown = $tira->record_show( project => $root, ref => $record->{ref} );
    is_deeply( [ map { $_->{id} } @{ $shown->{required_items} } ], [qw(REQ-001 REQ-002 REQ-003)],
        'three required items get three sequential ids' );

    # Remove the middle one directly from the record, the way test_steps
    # on this ticket describes - there is no required-item removal command.
    my @kept = grep { $_->{id} ne 'REQ-002' } @{ $shown->{required_items} };
    $shown->{required_items} = \@kept;
    $tira->_replace_record( project => $root, ref => $record->{ref}, record => $shown );

    my $fourth = $tira->required_item_add( author => 'claude',
        project => $root, ref => $record->{ref}, item => 'Fourth', status => 'pending',
    );
    is( $fourth->{id}, 'REQ-004', 'the next required item after a middle removal is REQ-004, not the collided REQ-002' );

    # Codex review: removing the MIDDLE item (above) only proves the
    # length-based bug collides with the surviving REQ-003, not that it
    # reissues the removed id itself. Removing the LAST (highest-numbered)
    # item is the direct case - and it is also the one case a max-scan
    # structurally cannot close: with REQ-004 gone, the highest surviving
    # id is REQ-003, so the next add is REQ-004 again. This is a known,
    # documented limit (README.md, SKILLS.md, Changes) shared with
    # conversation_add's own pre-existing pattern, not a regression - a
    # persisted counter, the way task ids get one, is what would close it,
    # and that is deliberately out of this ticket's scope. Pinned here so
    # nobody mistakes it for still-open work.
    $shown = $tira->record_show( project => $root, ref => $record->{ref} );
    @kept = grep { $_->{id} ne 'REQ-004' } @{ $shown->{required_items} };
    $shown->{required_items} = \@kept;
    $tira->_replace_record( project => $root, ref => $record->{ref}, record => $shown );

    my $fifth = $tira->required_item_add( author => 'claude',
        project => $root, ref => $record->{ref}, item => 'Fifth', status => 'pending',
    );
    is( $fifth->{id}, 'REQ-004', 'removing the LAST item reissues its own id on the next add - the documented max-scan limit, not a bug' );
}

# --- checklist_add: a removed entry does not collide with a surviving one -----

{
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Checklist items' );
    for my $item (qw(First Second Third)) {
        $tira->checklist_add( author => 'claude',
            project => $root, ref => $record->{ref}, item => $item, status => 'To Do',
        );
    }
    my $shown = $tira->record_show( project => $root, ref => $record->{ref} );
    is_deeply( [ map { $_->{id} } @{ $shown->{checklist} } ], [qw(CHK-001 CHK-002 CHK-003)],
        'three checklist entries get three sequential ids' );

    my @kept = grep { $_->{id} ne 'CHK-002' } @{ $shown->{checklist} };
    $shown->{checklist} = \@kept;
    $tira->_replace_record( project => $root, ref => $record->{ref}, record => $shown );

    my $fourth = $tira->checklist_add( author => 'claude',
        project => $root, ref => $record->{ref}, item => 'Fourth', status => 'To Do',
    );
    is( $fourth->{id}, 'CHK-004', 'the next checklist entry after a middle removal is CHK-004, not the collided CHK-002' );

    # Same documented max-scan limit as required_item_add above: removing
    # the LAST (highest-numbered) entry reissues its own id, which is the
    # one case a max-scan cannot close without a persisted counter.
    $shown = $tira->record_show( project => $root, ref => $record->{ref} );
    @kept = grep { $_->{id} ne 'CHK-004' } @{ $shown->{checklist} };
    $shown->{checklist} = \@kept;
    $tira->_replace_record( project => $root, ref => $record->{ref}, record => $shown );

    my $fifth = $tira->checklist_add( author => 'claude',
        project => $root, ref => $record->{ref}, item => 'Fifth', status => 'To Do',
    );
    is( $fifth->{id}, 'CHK-004', 'removing the LAST checklist entry reissues its own id on the next add - the documented max-scan limit, not a bug' );
}

# --- existing records with existing ids are unaffected ----------------------

{
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Unaffected by the fix' );
    my $first = $tira->required_item_add( author => 'claude',
        project => $root, ref => $record->{ref}, item => 'Untouched', status => 'pending',
    );
    is( $first->{id}, 'REQ-001', 'a fresh record still mints REQ-001 first, exactly as before' );
}

done_testing;

__END__

=head1 NAME

1085-an-id-that-came-back-from-the-dead.t - a removed required-item/checklist id does not collide with a surviving one

=head1 DESCRIPTION

TKT-642. C<required_item_add> and C<checklist_add> derived their next id
from C<scalar(@list) + 1>, correct only while nothing ever shortens the
list. C<conversation_add> already scans for the highest existing number
instead, so a removal never makes a later add collide with an id still on
the list.

Simulates a hand-removal (there is no required-item or checklist removal
command today) by splicing the record directly and writing it back via
C<_replace_record>, the same technique other tests in this suite already
use to reach past the public API, then proves the next add does not
collide with a surviving id. Also pins the one case a max-scan cannot
close: removing the currently-highest item and adding again reissues that
exact number - a known, documented limit shared with C<conversation_add>,
not something this ticket set out to fix.

=cut
