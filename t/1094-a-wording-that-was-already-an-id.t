#!/usr/bin/env perl

# TKT-693. checklist.update and required-action.update only ever accepted an
# id (CHK-NNN / REQ-NNN) via --id, though the wording an agent actually has
# in front of it is the entry's own text - printed on the card, quoted in
# the column template, and named in whatever instruction it is following.
# The natural attempt (passing that text where an id is expected) failed,
# and failed confusingly, because --item already exists and does something
# else entirely: it RENAMES an entry rather than addressing one.
#
# Michael's answer (Q-158): full text-addressing - accept an entry's own
# wording as an alternative to --id, refusing on ambiguity by naming both
# ids. --item keeps its current meaning (rename) unchanged.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

use lib 'lib';
use Tira;

my $now  = '2026-09-14T19:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->create_project( name => 'A wording that was already an id', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );

my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'First' );
my $ref    = $ticket->{ref};

$tira->checklist_add( project => $root, ref => $ref, author => 'ada', item => 'Update the docs' );
$tira->checklist_add( project => $root, ref => $ref, author => 'ada', item => 'Run the suite' );
$tira->checklist_add( project => $root, ref => $ref, author => 'ada', item => 'Run the suite' );
$tira->required_item_add( project => $root, ref => $ref, author => 'ada', item => 'Read the requirements', status => 'pending' );
$tira->required_item_add( project => $root, ref => $ref, author => 'ada', item => 'Run the suite', status => 'pending' );
$tira->required_item_add( project => $root, ref => $ref, author => 'ada', item => 'Run the suite', status => 'pending' );

# --- exact text ticks the right entry, same as its id would -----------------

{
    my $updated = $tira->checklist_update(
        project => $root, ref => $ref, author => 'ada',
        id => 'Update the docs', status => 'done',
        command => ['docs written'], proof => ['README updated'],
    );
    my ($entry) = grep { $_->{item} eq 'Update the docs' } @{ $tira->record_show( project => $root, ref => $ref )->{checklist} };
    is( $entry->{status}, 'done', 'checklist entry addressed by its own exact text is ticked' );
}

{
    my ($before) = grep { $_->{item} eq 'Read the requirements' } @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };
    $tira->required_item_update(
        project => $root, ref => $ref, author => 'ada',
        id => 'Read the requirements', status => 'done',
        command => ['read'], proof => ['requirements read'],
    );
    my ($after) = grep { $_->{id} eq $before->{id} } @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };
    is( $after->{status}, 'done', 'required-action entry addressed by its own exact text is ticked' );
}

# --- ambiguous text refuses, naming both ids, and changes nothing -----------

{
    my $before = $tira->record_show( project => $root, ref => $ref );
    my @before_status = map { $_->{status} } @{ $before->{checklist} };
    my @duplicate_ids = map { $_->{id} } grep { $_->{item} eq 'Run the suite' } @{ $before->{checklist} };
    is( scalar @duplicate_ids, 2, 'sanity: two checklist entries share the text "Run the suite"' );
    eval {
        $tira->checklist_update(
            project => $root, ref => $ref, author => 'ada',
            id => 'Run the suite', status => 'done',
            command => ['ran'], proof => ['ok'],
        );
    };
    my $err = $@;
    like( $err, qr/more than one/i, 'text matching two checklist entries refuses rather than guessing' );
    for my $id (@duplicate_ids) {
        like( $err, qr/\Q$id\E/, "the refusal names $id" );
    }
    my $after = $tira->record_show( project => $root, ref => $ref );
    is_deeply( [ map { $_->{status} } @{ $after->{checklist} } ], \@before_status, 'nothing changed when the address was ambiguous' );
}

{
    eval {
        $tira->required_item_update(
            project => $root, ref => $ref, author => 'ada',
            id => 'Run the suite', status => 'done',
            command => ['ran'], proof => ['ok'],
        );
    };
    like( $@, qr/more than one/i, 'text matching two required-action entries refuses rather than guessing' );
}

# --- text matching nothing gets the existing not-found refusal --------------

{
    eval {
        $tira->checklist_update(
            project => $root, ref => $ref, author => 'ada',
            id => 'Nothing on this card says this', status => 'done',
            command => ['ran'], proof => ['ok'],
        );
    };
    like( $@, qr/not found/i, 'text matching nothing still gets the existing not-found refusal' );
}

{
    eval {
        $tira->required_item_update(
            project => $root, ref => $ref, author => 'ada',
            id => 'Nothing on this card says this either', status => 'done',
            command => ['ran'], proof => ['ok'],
        );
    };
    like( $@, qr/not found/i, 'text matching nothing still gets the existing not-found refusal' );
}

# --- --item still RENAMES, and is not confused with addressing --------------

{
    my ($chk) = grep { $_->{item} eq 'Run the suite' } @{ $tira->record_show( project => $root, ref => $ref )->{checklist} };
    $tira->checklist_update(
        project => $root, ref => $ref, author => 'ada',
        id => $chk->{id}, item => 'Run the whole suite',
    );
    my ($renamed) = grep { $_->{id} eq $chk->{id} } @{ $tira->record_show( project => $root, ref => $ref )->{checklist} };
    is( $renamed->{item}, 'Run the whole suite', '--item still renames the entry addressed by --id' );
    is( $renamed->{status}, 'To Do', '--item alone does not also tick the entry' );
}

done_testing;

__END__

=head1 NAME

1094-a-wording-that-was-already-an-id.t - checklist/required-action entries can be addressed by their own text

=head1 DESCRIPTION

TKT-693. checklist_update and required_item_update only accepted an id via
--id, forcing every tick to be preceded by a ticket.show read just to find
it. Both now also accept an entry's own exact wording as the value of --id:
an unambiguous match ticks it, more than one match refuses and names every
matching id, and no match keeps the existing not-found refusal. --item's
existing meaning (rename) is unchanged.

=cut
