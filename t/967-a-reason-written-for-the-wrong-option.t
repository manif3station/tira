#!/usr/bin/env perl
# A rule that forbids --column is refused with the reason written for
# --age, so the refusal explains a delay that was never asked for.
#
# TKT-967, EPC-007. lib/Tira.pm's forbids loop refuses every forbidden
# option with ONE fixed sentence - "it reports the moment there is
# something to say, and a grace would only delay it" - written for --age.
# card-unassigned forbids column, enter AND age; declaring it with
# --column gets the --age sentence back, which describes a delay nobody
# asked for on an option that is not a delay at all.
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

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'Forbid', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'FBS', epic_prefix => 'FBE', ticket_prefix => 'FBT',
    );
    return ( $tira, $root );
}

# --- --column, forbidden by a card-scoped rule -------------------------------

{
    my ( $tira, $root ) = board();

    my $why = eval {
        $tira->policy_add( project => $root, rule => 'card-unassigned',
            action => 'log-only', column => 'backlog', author => 'claude' );
        '';
    } || $@;

    ok( length $why, 'card-unassigned refuses --column' );

    unlike( $why, qr/delay/i,
        'AND THE REASON DOES NOT TALK ABOUT A DELAY. --column is not a grace '
          . 'period - the rule watches the card wherever it sits, not the '
          . 'column, and today\'s message ("a grace would only delay it") '
          . 'describes an --age option this is not' );

    like( $why, qr/watches the card|card itself|wherever it sits/i,
        'and it says something about the card instead - the sentence a '
          . 'caller most needs, since believing a card-scoped rule is '
          . 'column-scoped is the exact misunderstanding this refusal exists '
          . 'to prevent. NOT just qr/card/, which the rule name '
          . '"card-unassigned" would satisfy on its own' );
}

# --- --enter, the other non-age option ---------------------------------------

{
    my ( $tira, $root ) = board();

    my $why = eval {
        $tira->policy_add( project => $root, rule => 'card-unassigned',
            action => 'log-only', enter => 1, author => 'claude' );
        '';
    } || $@;

    ok( length $why, 'card-unassigned refuses --enter too' );

    unlike( $why, qr/delay/i, 'and its reason does not talk about a delay either' );
}

# --- a rule with no entry in the option table still gets a real reason ------
#
# unpushed-work forbids --pattern, and nothing else does. Codex review caught
# that the option-only table's fallback silently gave --pattern the --age
# wording, which is false: --pattern is refused because the rule's own body
# never reads it, not because it is a grace period.

{
    my ( $tira, $root ) = board();

    my $why = eval {
        $tira->policy_add( project => $root, rule => 'unpushed-work',
            action => 'log-only', age => '1h', pattern => 'CODE', author => 'claude' );
        '';
    } || $@;

    ok( length $why, 'unpushed-work refuses --pattern' );

    unlike( $why, qr/delay/i,
        'and its reason is not the --age wording - --pattern is refused '
          . "because the rule's own body never reads it, not because it is a "
          . 'grace period' );
}

# --- a rule that forbids --column for a DIFFERENT reason gets its own one ---
#
# column-unwatched is whole-board (it is about which columns OTHER policies
# name), not card-scoped like card-unassigned/upgrade-unreviewed. The
# option-only reason for --column ("it watches the card wherever it sits")
# would tell a column-unwatched caller their card sits somewhere, when this
# rule has no card to sit in at all - caught by Codex review.

{
    my ( $tira, $root ) = board();

    my $why = eval {
        $tira->policy_add( project => $root, rule => 'column-unwatched',
            action => 'log-only', column => 'backlog', author => 'claude' );
        '';
    } || $@;

    ok( length $why, 'column-unwatched refuses --column' );

    unlike( $why, qr/wherever it sits/i,
        'but NOT with the card-scoped reason - this rule has no card to sit '
          . 'in, since it watches which columns other policies name across '
          . 'the whole board' );

    like( $why, qr/other polic/i,
        "and says it is about what OTHER policies name instead" );
}

# --- --age keeps its own wording, unchanged ----------------------------------
#
# The control: a rule refusing --age genuinely IS refusing a grace period,
# and that sentence must not be touched by giving --column/--enter their own.

{
    my ( $tira, $root ) = board();

    my $why = eval {
        $tira->policy_add( project => $root, rule => 'checklist-unmoved',
            action => 'log-only', age => '10m', author => 'claude' );
        '';
    } || $@;

    ok( length $why, 'checklist-unmoved refuses --age' );

    like( $why, qr/delay/i,
        'and KEEPS the delay wording - an --age refusal genuinely is about a '
          . 'grace period, so the fix must not touch this sentence' );
}

done_testing();

__END__

=head1 NAME

967-a-reason-written-for-the-wrong-option.t - a forbidden option's refusal
names what that option actually means, not always --age's reason

=head1 WHY

TKT-967. C<policy_add>'s forbids loop refused every forbidden option with one
fixed sentence written for C<--age> - "a grace would only delay it". A rule
that forbids C<--column> or C<--enter> (C<card-unassigned> forbids all
three) got that sentence back regardless, describing a delay that was never
asked for on an option that is not a delay at all.

=head1 WHAT IS ASSERTED

That C<--column> and C<--enter> are refused without the delay wording, and
say something about the card instead. That C<--age> keeps its own delay
wording unchanged - the control, since the fix must give the other two
options their own reason without touching the one sentence that was already
right.

=cut
