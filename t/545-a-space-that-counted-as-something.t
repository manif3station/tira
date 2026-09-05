#!/usr/bin/env perl
# Five commands guard the content they store, and they did not agree.
#
# TKT-909. Two refused only the empty string (eq ''): evidence_add,
# checklist_add, required_item_add. Two already refused whitespace-only
# (!~ /\S/): warning_add, question_answer - settled on TKT-585, for the
# proof pair: "Whitespace counts as empty: a space is not a smaller piece
# of evidence than none." That reasoning was never carried to the other
# three.
#
# MOST ON evidence_add: it is what a release gate reads back as the record
# of what was proved. A summary of three spaces satisfied every check that
# asks whether evidence EXISTS and told the next reader nothing - the same
# shape as the empty comment TKT-753 closed, on a record that matters more.
#
# THE UPDATE VERBS ARE A SEPARATE, DELIBERATE DECISION (CHK-004), not an
# oversight folded in here. checklist_update and required_item_update take
# the same fields, and whether blanking an EXISTING item is a legitimate
# edit is a different question from whether creating a blank one is -
# TKT-753 hit exactly this and left comment_update out of scope, with the
# reasoning recorded, and t/448 then used comment_update as the one door
# still open, which turned out to be the right shape. Left alone here for
# the same reason and the same precedent.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new;
$tira->project_new(
    project => $root, name => 'Blanks', dir => $root,
    members => ['claude'], columns => ['backlog, implement, done'],
    sow_prefix => 'BLS', epic_prefix => 'BLE', ticket_prefix => 'BLT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card that will collect blank content' );

# --- the one that matters most: evidence_add --------------------------------

{
    my $refused = !eval {
        $tira->evidence_add( project => $root, ref => $card->{ref},
            author => 'claude', summary => '   ' );
        1;
    };
    ok( $refused,
        'EVIDENCE_ADD REFUSES A WHITESPACE-ONLY SUMMARY - a release gate reads '
          . 'this back as the record of what was proved' )
      or diag('evidence_add stored a summary of three spaces');
    like( $@, qr/summary is required/i, 'naming what is missing' );
}

# --- checklist_add -----------------------------------------------------------

{
    my $refused = !eval {
        $tira->checklist_add( project => $root, ref => $card->{ref}, author => 'claude',
            item => '  ', status => 'pending' );
        1;
    };
    ok( $refused, 'CHECKLIST_ADD REFUSES A WHITESPACE-ONLY ITEM' )
      or diag('checklist_add stored an item with no text in it');
    like( $@, qr/item is required/i, 'naming what is missing' );
}

# --- required_item_add --------------------------------------------------------

{
    my $refused = !eval {
        $tira->required_item_add( project => $root, ref => $card->{ref}, author => 'claude',
            item => "\t", status => 'pending' );
        1;
    };
    ok( $refused, 'REQUIRED_ITEM_ADD REFUSES A WHITESPACE-ONLY ITEM' )
      or diag('required_item_add stored an item made only of a tab');
    like( $@, qr/item is required/i, 'naming what is missing' );
}

# --- and a real value still works, for all three ------------------------------

{
    my $evidence = $tira->evidence_add( project => $root, ref => $card->{ref},
        author => 'claude', summary => 'Real proof' );
    is( $evidence->{summary}, 'Real proof', 'evidence_add still works with real content' );

    my $checklist = $tira->checklist_add( project => $root, ref => $card->{ref}, author => 'claude',
        item => 'Real checklist item', status => 'pending' );
    is( $checklist->{item}, 'Real checklist item', 'checklist_add still works with real content' );

    my $required = $tira->required_item_add( project => $root, ref => $card->{ref}, author => 'claude',
        item => 'Real required item', status => 'pending' );
    is( $required->{item}, 'Real required item', 'required_item_add still works with real content' );
}

# --- no existing stored data is rewritten -------------------------------------
#
# A board already carries whatever was written before this refusal existed -
# checklist_add's own vocabulary validation records the same rule, and the
# fix must not reach backward and touch what is already on disk.

{
    my $record = $tira->record_show( project => $root, ref => $card->{ref} );
    push @{ $record->{checklist} },
      { id => 'CHK-999', item => '   ', status => 'pending',
        created_at => '2026-01-01T00:00:00Z', last_updated => '2026-01-01T00:00:00Z' };
    $tira->_replace_record( project => $root, ref => $card->{ref}, record => $record );

    my $after = $tira->record_show( project => $root, ref => $card->{ref} );
    my ($pre_existing) = grep { $_->{id} eq 'CHK-999' } @{ $after->{checklist} };
    is( $pre_existing->{item}, '   ',
        'A CHECKLIST ITEM WRITTEN BEFORE THIS FIX STILL READS UNCHANGED - the '
          . 'refusal is at the point of writing only, matching checklist_add\'s '
          . 'own precedent for its vocabulary check' );
}

done_testing();

__END__

=head1 NAME

545-a-space-that-counted-as-something.t - three commands accepted a value made only of spaces

=head1 WHY

TKT-909. C<warning_add> and C<question_answer> refuse a whitespace-only
value (TKT-585); C<evidence_add>, C<checklist_add> and C<required_item_add>
refused only the literal empty string, so a summary or item of pure spaces
was stored, exited 0, and printed back as if it were content. Worst on
C<evidence_add>, which a release gate reads as the record of what was
proved.

=head1 WHAT IS ASSERTED

That all three now refuse whitespace-only content with the same message
they already give for the empty string; that real content still works;
and that a whitespace-only value written before this fix existed still
reads back unchanged - the refusal is at the point of writing only.

=cut
