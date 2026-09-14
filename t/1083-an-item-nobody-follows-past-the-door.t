#!/usr/bin/env perl
# TKT-612. His own board's history: he moved a card backlog -> next-to-work-on
# in the browser (ungated by design, TKT-426/452), with all eight of its
# backlog required actions still unmarked. That move is not the complaint -
# what happens to the items afterwards is: _column_required_action_violation
# only ever reads items tagged with the card's CURRENT column, so anything
# tagged with a column the card has already left is invisible to the CLI
# departure gate, and no police rule reads required_items at all. Those items
# can never block anything again and nothing will ever mention them.
#
# His own answer, on this card: start with the cheapest of three candidates -
# a police rule that reports unmet required actions on a card regardless of
# which column tagged them, changing no move behaviour.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );

sub board_at {
    my ($name) = @_;
    my $tira = Tira->new( clock => sub {'2026-09-14T09:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, $name );
    $tira->project_new(
        name => $name, dir => $root, members => ['claude'],
        columns => ['backlog, tests-red, implement, done'],
    );
    $tira->policy_add(
        project => $root, rule => 'required-action-stranded', action => 'bridge-reminder',
    );
    return ( $tira, $root );
}

sub reported {
    my ( $tira, $root, $name ) = @_;
    my $pass = $tira->police_pass(
        project => $root,
        store   => File::Spec->catdir( $tmp, "store-$name" ),
        world   => {},
    );
    return $pass->{violations} // [];
}

# --- a required item stranded by a skipped column is reported --------------
{
    my ( $tira, $root ) = board_at('stranded');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Dragged past its own door' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'backlog', item => 'Fill in the fields', status => 'pending' );

    # The browser move: ungated, exactly as TKT-426/452 leave it. Going
    # straight to implement, past both backlog and tests-red, is the shape
    # that stranded the owner's own real card.
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );

    my $violations = reported( $tira, $root, 'stranded' );
    is( scalar @{$violations}, 1, 'the item tagged backlog, now unreachable from implement, is reported' );
    like( $violations->[0]{detail}, qr/Fill in the fields/, 'and the detail names the stranded item' );
    like( $violations->[0]{detail}, qr/backlog/, 'and the column it was stranded in' );
}

# --- a card with nothing outstanding produces no report ---------------------
{
    my ( $tira, $root ) = board_at('clean');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Nothing left behind' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'backlog', item => 'Fill in the fields', status => 'pending' );
    $tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref},
        id => 'REQ-001', status => 'done', command => ['filled them in'], proof => ['confirmed'] );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );

    is( scalar @{ reported( $tira, $root, 'clean' ) }, 0,
        'a card with nothing outstanding produces no report' );
}

# --- an item still in the CURRENT column is not "stranded" ------------------
{
    my ( $tira, $root ) = board_at('current');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Still at its own door' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'backlog', item => 'Fill in the fields', status => 'pending' );

    is( scalar @{ reported( $tira, $root, 'current' ) }, 0,
        "an unmet item in the card's own current column is the departure gate's business, not this rule's" );
}

# --- a card that has genuinely finished is settled, like a discarded one ----
#
# TKT-1087. Declaring this rule board-wide surfaced 53 findings on the first
# pass, most naming cards already in 'done' - the source only exempted
# 'discard', not the board's own ending column(s), so a card whose real work
# finished long before this rule existed kept reporting forever with no way
# to settle it short of hand-marking every stale item. This board names no
# column --terminal, so 'done' (its last column) is assumed to be the
# ending, the same default column_endings uses everywhere else.

{
    my ( $tira, $root ) = board_at('finished');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Reached the end anyway' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'backlog', item => 'Fill in the fields', status => 'pending' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'done', author => 'claude' );

    is( scalar @{ reported( $tira, $root, 'finished' ) }, 0,
        'a card that reached done is settled, even with an old item stranded in a column it left on the way' );
}

# --- an explicitly declared terminal column, not just the 'done' default ---
#
# Codex review: the test above only proves the IMPLICIT fallback (a board
# that has named no ending gets 'done' assumed). It does not prove a board
# that has actually declared its own ending column via
# C<tira.column.update --terminal> is honoured too - the whole point of
# reusing C<column_endings> rather than hard-coding the string 'done'.

{
    my ( $tira, $root ) = board_at('declared-terminal');
    $tira->column_update( project => $root, type => 'ticket', name => 'implement', terminal => 1 );
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'A board with its own ending' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'backlog', item => 'Fill in the fields', status => 'pending' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );

    is( scalar @{ reported( $tira, $root, 'declared-terminal' ) }, 0,
        "a board that declared 'implement' its own ending settles a card there too, not only in the default 'done'" );

    # column_endings' own documented design (TKT-300): marking one column
    # terminal does not switch OFF the 'done' default for every other -
    # that was the all-or-nothing trap mt5-ai paid for once already. So a
    # second card that goes all the way to 'done' on this same board is
    # STILL settled, exactly as if 'implement' had never been declared -
    # the two endings compose rather than replace each other.
    my $second = $tira->create_record( project => $root, type => 'ticket', title => 'Reached done, which is still an ending too' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $second->{ref},
        column => 'backlog', item => 'Fill in the fields', status => 'pending' );
    $tira->record_move( project => $root, ref => $second->{ref}, column => 'implement', author => 'claude' );
    $tira->record_move( project => $root, ref => $second->{ref}, column => 'done', author => 'claude' );

    is( scalar @{ reported( $tira, $root, 'declared-terminal' ) }, 0,
        "declaring 'implement' terminal does not undo the 'done' default - a card that reaches done is still settled too" );
}

# --- the per-type %endings cache does not leak across record kinds ---------
#
# Codex review: %endings is keyed by $type and filled once per type with
# //=, the same shape %positions already used safely - but that shape was
# never exercised with more than one type on the same pass before. A ticket
# and a sow, each stranded, on the same board: if the cache mixed them up
# (reused the first type's answer for the second, or the second call built
# nothing because %endings already had a false-y entry from the first),
# one of the two would go unreported.

{
    my ( $tira, $root ) = board_at('mixed-types');
    my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'A stranded ticket' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $ticket->{ref},
        column => 'backlog', item => 'Fill in the fields', status => 'pending' );
    $tira->record_move( project => $root, ref => $ticket->{ref}, column => 'implement', author => 'claude' );

    my $sow = $tira->create_record( project => $root, type => 'sow', title => 'A stranded sow' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $sow->{ref},
        column => 'backlog', item => 'Fill in the fields', status => 'pending' );
    $tira->record_move( project => $root, ref => $sow->{ref}, column => 'implement', author => 'claude' );

    my $violations = reported( $tira, $root, 'mixed-types' );
    is( scalar @{$violations}, 2,
        'both a stranded ticket and a stranded sow on the same board are reported - the per-type endings cache does not lose either one' );
    my %by_ref = map { $_->{ref} => 1 } @{$violations};
    ok( $by_ref{ $ticket->{ref} }, 'the ticket is one of them' );
    ok( $by_ref{ $sow->{ref} }, 'the sow is the other' );
}

# --- an exempted item is not reported ---------------------------------------
{
    my ( $tira, $root ) = board_at('exempted');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Excused on the way past' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'backlog', item => 'Fill in the fields', status => 'pending' );
    $tira->record_update( project => $root, ref => $card->{ref}, author => 'claude',
        required_exempt => ['Fill in the fields'], exempt_reason => ['Not needed for this card'] );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );

    is( scalar @{ reported( $tira, $root, 'exempted' ) }, 0,
        'an item this card is exempt from is not reported as stranded' );
}

# --- a discarded card is exempt throughout, same as every other rule --------
{
    my ( $tira, $root ) = board_at('discarded');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Set aside with work outstanding' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'backlog', item => 'Fill in the fields', status => 'pending' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );
    $tira->record_discard( author => 'claude', project => $root, ref => $card->{ref} );

    is( scalar @{ reported( $tira, $root, 'discarded' ) }, 0,
        'a discarded card is exempt throughout, the same as every other machine-watching rule' );
}

# --- an item attached to a column not yet REACHED is not "stranded" --------
#
# Codex review caught this: the first draft compared columns with `ne`
# rather than by board order, which would have reported an item manually
# attached to a column ahead of the card (required-action.add can be given
# any --column) as though it had already been skipped - the opposite of
# what "stranded" means.
{
    my ( $tira, $root ) = board_at('ahead');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Not there yet' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'done', item => 'Something for later', status => 'pending' );

    is( scalar @{ reported( $tira, $root, 'ahead' ) }, 0,
        'an item attached to a column the card has not reached yet is not reported as stranded' );
}

# --- an unmet item tagged 'discard' itself is never reported ---------------
#
# Codex review caught this too: a required_items entry can in principle
# carry column => 'discard' (a discard column could declare its own entry
# template). If a card were ever restored elsewhere with such an entry
# still unmet, a bare position comparison would report it - discard is
# never a column work is stranded FROM, so it is excluded by name as well
# as by order.
{
    my ( $tira, $root ) = board_at('was-discarded');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Restored with a discard-tagged leftover' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'discard', item => 'Left over from being set aside', status => 'pending' );

    is( scalar @{ reported( $tira, $root, 'was-discarded' ) }, 0,
        "an item tagged 'discard' itself is never reported as stranded, whatever the card's current column" );
}

done_testing;

__END__

=head1 NAME

1083-an-item-nobody-follows-past-the-door.t - required actions stranded by a skipped column are reported

=head1 DESCRIPTION

TKT-612. C<_column_required_action_violation> only reads items tagged with
a card's CURRENT column, so an item tagged with a column the card has
already left - by a browser move, which is deliberately ungated
(TKT-426/452) - was invisible to every gate and every rule, forever.

The owner's own choice of the three candidates offered: a new police rule,
C<required-action-stranded>, that reports any unmet required item whose
column is not the card's current one, respecting the same exemption
mechanism (C<--exempt-required>/C<--exempt-reason>) every other required-
action check already honours, and staying silent for a discarded card the
same way every other machine-watching rule does.

=cut
