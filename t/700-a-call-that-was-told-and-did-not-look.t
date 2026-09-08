#!/usr/bin/env perl
# TKT-700. required_item_update takes --column and never reads it - the id
# alone decides which item is touched, so a caller who names the right
# column and the wrong id succeeds anyway, with valid-looking proof filed
# against the wrong item. Measured live on TKT-657: six proofs landed two
# items early, because the items were numbered off a different template
# than the caller expected and nothing checked the column that was named
# right there in the call.
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
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Told and ignored', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'TIS', epic_prefix => 'TIE', ticket_prefix => 'TIT',
);

$tira->column_update( project => $root, type => 'ticket', name => 'implement',
    required_action => ['Prove the thing'] );

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card with items in two columns', author => 'claude',
    problem_or_feature => 'x', solution_needed => 'x', key_details => ['x'],
    deliverables => ['x'], acceptance_criteria => ['x'], test_steps => ['x'],
    bdd => ['x'], atdd => ['x'], description => 'x', scope_in => ['x'], scope_out => ['x'],
);

# One item from backlog's own template, one from implement's - the shape of
# the incident: two columns' items sitting on one card, numbered together.
$tira->required_item_add( project => $root, type => 'ticket', ref => $card->{ref},
    item => 'A backlog item', status => 'pending', column => 'backlog', author => 'claude' );
$tira->required_item_add( project => $root, type => 'ticket', ref => $card->{ref},
    item => 'Prove the thing', status => 'pending', column => 'implement', author => 'claude' );

my $record   = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
my ($backlog_item) = grep { $_->{column} eq 'backlog' } @{ $record->{required_items} };
my ($implement_item) = grep { $_->{column} eq 'implement' } @{ $record->{required_items} };

# --- the reply already names what it marked ---------------------------------

{
    my $updated = $tira->required_item_update(
        project => $root, type => 'ticket', ref => $card->{ref}, author => 'claude',
        id => $implement_item->{id}, status => 'done',
        command => ['prove it'], proof => ['it passed'],
    );
    is( $updated->{id}, $implement_item->{id}, 'the reply names the id it marked' );
    is( $updated->{item}, 'Prove the thing', 'and the text of what it marked' );

    # Reset for the tests below.
    $tira->required_item_update( project => $root, type => 'ticket', ref => $card->{ref},
        author => 'claude', id => $implement_item->{id}, status => 'pending' );
}

# --- a --column that matches is unaffected ----------------------------------

{
    my $updated = eval {
        $tira->required_item_update(
            project => $root, type => 'ticket', ref => $card->{ref}, author => 'claude',
            id => $implement_item->{id}, status => 'done', column => 'implement',
            command => ['prove it'], proof => ['it passed'],
        );
    };
    ok( $updated, 'a matching --column is not refused' ) or diag($@);
    is( $updated->{status}, 'done', 'and the update went through' );

    $tira->required_item_update( project => $root, type => 'ticket', ref => $card->{ref},
        author => 'claude', id => $implement_item->{id}, status => 'pending' );
}

# --- the incident: right column named, wrong id given -----------------------
#
# The caller believed it was marking implement's item and said so with
# --column implement - but the id it actually typed belongs to backlog.

{
    my $ok = eval {
        $tira->required_item_update(
            project => $root, type => 'ticket', ref => $card->{ref}, author => 'claude',
            id => $backlog_item->{id}, status => 'done', column => 'implement',
            command => ['prove it'], proof => ['it passed'],
        );
        1;
    };
    ok( !$ok, 'a --column that disagrees with the item is refused rather than silently applied' );
    like( $@ // '', qr/backlog/, 'the refusal names the column the item is actually in' );
    like( $@ // '', qr/implement/, 'and the column the caller named' );

    my $unchanged = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    my ($still) = grep { $_->{id} eq $backlog_item->{id} } @{ $unchanged->{required_items} };
    is( $still->{status}, 'pending', 'and the wrongly-addressed item was not touched' );
}

# --- omitting --column changes nothing --------------------------------------

{
    my $updated = eval {
        $tira->required_item_update(
            project => $root, type => 'ticket', ref => $card->{ref}, author => 'claude',
            id => $backlog_item->{id}, status => 'done',
            command => ['done another way'], proof => ['it passed'],
        );
    };
    ok( $updated, 'omitting --column still works exactly as before' ) or diag($@);
    is( $updated->{status}, 'done', 'and the update applied' );
}

# --- checklist_update gets the same guard, against the CARD'S own column ---
# --- since a checklist entry has no column of its own -----------------------

{
    $tira->checklist_add( project => $root, type => 'ticket', ref => $card->{ref},
        author => 'claude', item => 'Write the note', status => 'pending' );
    my $with_checklist = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    my ($chk) = @{ $with_checklist->{checklist} };

    my $ok = eval {
        $tira->checklist_update( project => $root, type => 'ticket', ref => $card->{ref}, author => 'claude',
            id => $chk->{id}, status => 'done', column => 'done',
            command => ['write it'], proof => ['written'] );
        1;
    };
    ok( !$ok, 'checklist_update refuses a --column that disagrees with the card\'s own column' );
    like( $@ // '', qr/backlog/, 'naming the card\'s real column' );
    like( $@ // '', qr/\bdone\b/, 'and the column the caller named' );

    my $matching = eval {
        $tira->checklist_update( project => $root, type => 'ticket', ref => $card->{ref}, author => 'claude',
            id => $chk->{id}, status => 'done', column => 'backlog',
            command => ['write it'], proof => ['written'] );
    };
    ok( $matching, 'a matching --column is not refused on checklist_update' ) or diag($@);
}

done_testing();

__END__

=head1 NAME

700-a-call-that-was-told-and-did-not-look.t - a caller's own --column is
checked, not just accepted

=head1 DESCRIPTION

TKT-700. required_item_update ignored --column entirely, finding an item by
id alone - so a call carrying the right column and the wrong id succeeded,
with genuine proof filed against the wrong item. --column is now a guard: a
call whose --column agrees with the item's own is unaffected, a call whose
--column disagrees is refused naming both, and a call with no --column
behaves exactly as before. checklist_update gets the same guard against the
card's own current column, since a checklist entry carries none of its own.
The reply from a successful call already named the item's id and text
before this fix - unchanged, and asserted here as the standing behaviour.

=cut
