#!/usr/bin/env perl
# TKT-956, found while filling in TKT-948 - the card the upgrade gate raised
# on a real version bump, by hand, because it arrived with nothing on it.
#
# THE BUG. _raise_upgrade_gate creates its card with only title, description,
# priority and a label - none of the other fields tira.ticket.missing and
# tools/card-holes check for (problem_or_feature, solution_needed,
# key_details, deliverables, acceptance_criteria, test_steps, bdd, atdd,
# scope_in, scope_out) and no parent. Confirmed 3+ times this session
# (TKT-948, TKT-974, TKT-983 were each the upgrade gate's own card, hand-
# filled every time): 9-12 empty fields and an orphan-card violation, on
# every single upgrade.
#
# THE FIX has two parts. The nine text/array fields get real, generic
# content - true of any upgrade, not guessed at for this one, because the
# gate cannot know which Changes entry matters to a given board; that
# judgement is the review the card exists to hold. The parent problem is
# not an auto-link guess at which epic fits - it is the same shape a SOW's
# missing parent already is: upgrade-gate joins standalone in CARD_EXEMPT,
# because the engine raised this card itself and cannot say which feature
# epic it belongs under.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $tira = Tira->new( clock => sub {'2026-09-07T09:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Gate Holes', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'GHS', epic_prefix => 'GHE', ticket_prefix => 'GHT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    return ( $tira, $root );
}

# --- the card the gate raises is complete, by the same check the push gate uses ---

{
    my ( $tira, $root ) = board();
    $tira->_raise_upgrade_gate( $root, { from => '5.84', to => '5.85' } );

    my ($record) = @{ $tira->record_list( project => $root, type => 'ticket' ) };
    ok( $record, 'the gate raised a card' ) or diag('no card was raised at all');

    my $missing = $tira->card_missing( project => $root, ref => $record->{ref} );
    is_deeply( $missing, [],
        "d2 tira.ticket.missing reports nothing missing on the card the gate raised - "
          . 'the same check tools/card-holes and orphan-card both read' )
      or diag( 'missing: ' . join( ', ', @{$missing} ) );
}

# --- and card_holes, the whole-board sweep the push gate runs, agrees --------

{
    my ( $tira, $root ) = board();
    $tira->_raise_upgrade_gate( $root, { from => '5.84', to => '5.85' } );

    my $holes = $tira->card_holes( project => $root, type => 'ticket' );
    is_deeply( $holes, [],
        'tools/card-holes reports the board complete - a card-holes violation on every '
          . 'single upgrade is exactly what this ticket is about' )
      or diag( 'holes: ' . join( ', ', map { "$_->{ref}: " . join( ',', @{ $_->{missing} } ) } @{$holes} ) );
}

# --- the card says something worth reading, not a placeholder ---------------

{
    my ( $tira, $root ) = board();
    $tira->_raise_upgrade_gate( $root, { from => '5.84', to => '5.85' } );

    my ($record) = @{ $tira->record_list( project => $root, type => 'ticket' ) };
    like( $record->{problem_or_feature}, qr/5\.84/, 'problem_or_feature names the actual version range' );
    like( $record->{solution_needed}, qr/tira\.policy\.undeclared/,
        'solution_needed names the actual command the review runs' );
    ok( scalar @{ $record->{acceptance_criteria} } >= 1, 'acceptance_criteria is not empty' );
    ok( scalar @{ $record->{test_steps} } >= 1, 'test_steps is not empty' );
}

# --- a project's own choice of standalone still works, unaffected -----------
#
# The exemption is additive. A card that earned standalone the old way still
# does, and CARD_EXEMPT is read from, not duplicated, by both rules that use
# it - checked directly so a future third exemption cannot silently diverge
# from the two the engine already agrees on.

{
    my ( $tira, $root ) = board();
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card that stands alone on purpose', labels => ['standalone'] );
    my $missing = $tira->card_missing( project => $root, ref => $card->{ref} );
    ok( !grep { $_ eq 'parent' } @{$missing},
        'a standalone-labelled card is still exempt from needing a parent' );
}

# --- the exemption is declared once, read by both rules that need it --------

{
    my $engine = Suite::engine_source();
    # non-empty is the whole claim: every check below would pass on an
    # unreadable file's emptiness alone.
    like( $engine, qr/\S/, 'the engine source is there to be read' );

    my ($exempt) = $engine =~ /(my \s+ %CARD_EXEMPT \s* = .*? ;)/xs;
    like( $exempt // '', qr/upgrade-gate/,
        "CARD_EXEMPT's own parent exemption list names upgrade-gate, asserted by content so a "
          . 'match on some other variable could not satisfy this' );
    like( $exempt // '', qr/standalone/,
        'and still names standalone - the new exemption is additive, not a replacement' );
}

done_testing();

__END__

=head1 NAME

588-a-gate-that-raises-a-hole.t - the upgrade gate's own card is complete

=head1 DESCRIPTION

TKT-956. C<_raise_upgrade_gate> created its card with a title, a description
and a priority - none of the other fields C<tira.ticket.missing> and
C<tools/card-holes> check for, and no parent. Confirmed three times this
session by hand-filling the card on a real version bump each time: 9-12
empty fields and an C<orphan-card> violation, on every single upgrade.

This holds the fix in place: the nine text/array fields carry real, generic
content true of any upgrade, and C<upgrade-gate> joins C<standalone> in
C<CARD_EXEMPT> - the engine raised this card itself and cannot say which
feature epic it belongs under, the same reason a SOW has no parent.

=cut
