#!/usr/bin/env perl
# TKT-827, found by the two-hourly improvement hunt on 2026-09-01 and requeued
# by him on 2026-09-06 after he had read the measurement left on the card.
#
# THE CLAIM THE COMMAND MAKES ABOUT ITSELF is the fault. docs/commands.md
# documents tira.outstanding as answering "the same project-wide totals TKT-797
# already put in the browser dashboard's sticky header". It is not the same:
#
#   outstanding_summary  calls record_list( project, type ) with no column
#                        filter at all, and record_list never mentions discard
#                        anywhere in its body - so it walks every column
#                        directory under .tira/<type>/, discard included.
#   dashboard()          eight lines below it excludes the discard column
#                        explicitly: grep { $_->{name} ne 'discard' || ... }.
#
# So a card somebody SET ASIDE, still carrying a question nobody answered, is
# counted by the terminal total and not by the header it claims to match. Two
# numbers, one name, and the difference only appears when a discarded card
# happens to hold an unanswered question - which is why nothing looked wrong
# for months.
#
# MEASURED ON THE REAL BOARD, twice: record_list(ticket) returned 964 cards of
# which 165 were in discard, and outstanding_summary walked all 964.
#
# AND A TRAP FOR WHOEVER FIXES IT, worth stating because the nearest pattern to
# copy teaches the opposite of what is true: include_discard is INERT when
# passed to record_list. Five call sites pass it and nothing reads it, so
# policy_evaluate's "record_list( ..., include_discard => 1 )" followed by a
# hand-written discard filter reads as though the default were safe. It is not:
# the default is everything.
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
    my $tira = Tira->new( clock => sub {'2026-09-06T14:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Set Aside', dir => $root, members => [ 'claude', 'michael' ],
        columns => ['backlog, implement, done'],
        sow_prefix => 'SAS', epic_prefix => 'SAE', ticket_prefix => 'SAT',
    );
    return ( $tira, $root );
}

# --- a question on a discarded card is not outstanding ---------------------
#
# The whole card. Setting work aside is a decision; the question on it went
# with it, and a total that keeps counting it is reporting work nobody is
# waiting on.

{
    my ( $tira, $root ) = board();
    my $live = $tira->create_record( project => $root, type => 'ticket',
        title => 'still being worked' );
    my $aside = $tira->create_record( project => $root, type => 'ticket',
        title => 'set aside with a question on it' );

    $tira->question_add( project => $root, ref => $live->{ref},
        author => 'claude', text => 'Which way for the live one?' );
    $tira->question_add( project => $root, ref => $aside->{ref},
        author => 'claude', text => 'Which way for the one nobody is doing?' );
    $tira->record_move( project => $root, ref => $aside->{ref},
        author => 'claude', column => 'discard' );

    my $summary = $tira->outstanding_summary( project => $root );
    is( $summary->{questions}, 1,
        'a question on a DISCARDED card is not counted - the card was set aside and the '
          . 'question went with it, so nobody is waiting on an answer' );
}

# --- and it agrees with the header it says it matches ----------------------
#
# The command's own documented claim, asserted rather than trusted. The
# dashboard is what the browser header counts, and it excludes discard.

{
    my ( $tira, $root ) = board();
    for my $n ( 1 .. 3 ) {
        my $card = $tira->create_record( project => $root, type => 'ticket',
            title => "card $n" );
        $tira->question_add( project => $root, ref => $card->{ref},
            author => 'claude', text => "question $n" );
        $tira->record_move( project => $root, ref => $card->{ref},
            author => 'claude', column => 'discard' )
          if $n == 3;
    }

    my $summary = $tira->outstanding_summary( project => $root );

    # What the browser header actually counts: cards the dashboard renders,
    # which is the dashboard WITHOUT discard, that are waiting on somebody.
    #
    # The shape is {type}{column}[cards], not {column}[cards] - read back from
    # the real answer rather than assumed, after the first version of this
    # section died on "Not an ARRAY reference".
    my $board = $tira->dashboard( project => $root, type => 'ticket',
        summary => 1, with_questions => 1 );
    my $waiting = 0;
    for my $type ( grep { !/\A_/ } keys %{$board} ) {
        for my $column ( keys %{ $board->{$type} || {} } ) {
            $waiting += grep { $_->{waiting} } @{ $board->{$type}{$column} || [] };
        }
    }

    is( $summary->{questions}, $waiting,
        'the terminal total and the dashboard header agree, which is the claim the command '
          . 'makes about itself in the documentation' );
    is( $summary->{questions}, 2, 'and both count the two live cards, not the third' );
}

# --- and a caller who wants the whole board can still ask -------------------
#
# --include-discard was ACCEPTED by this command before TKT-827 and did
# nothing: the parser is shared, so the flag parsed, reached the arguments, and
# was never read. Making the default match the header without making the flag
# work would have left that silently-ignored option in place, which is the
# fault the option guard exists to prevent.

{
    my ( $tira, $root ) = board();
    my $aside = $tira->create_record( project => $root, type => 'ticket',
        title => 'set aside with a question on it' );
    $tira->question_add( project => $root, ref => $aside->{ref},
        author => 'claude', text => 'Which way?' );
    $tira->record_move( project => $root, ref => $aside->{ref},
        author => 'claude', column => 'discard' );

    is( $tira->outstanding_summary( project => $root )->{questions}, 0,
        'by default the set-aside card is not counted' );
    is( $tira->outstanding_summary( project => $root, include_discard => 1 )->{questions}, 1,
        'and --include-discard counts it again - the flag was accepted and ignored before '
          . 'this card, which is worse than not offering it' );
}

# --- an answered question was never outstanding ----------------------------
#
# The direction a careless filter breaks. This already worked and must keep
# working, or the fix has traded one wrong number for another.

{
    my ( $tira, $root ) = board();
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'asked and answered' );
    my $question = $tira->question_add( project => $root, ref => $card->{ref},
        author => 'claude', text => 'Which way?' );
    $tira->question_answer( project => $root, ref => $card->{ref},
        id => $question->{id}, author => 'michael', text => 'that way' );

    my $summary = $tira->outstanding_summary( project => $root );
    is( $summary->{questions}, 0, 'an answered question is not outstanding' );
}

# --- the tasks half is unchanged -------------------------------------------
#
# outstanding_summary answers two numbers and this card is about one of them.
# The tasklist has no columns and nothing to discard, so its count must come
# through untouched.

{
    my ( $tira, $root ) = board();
    $tira->tasklist_add( project => $root, text => 'something still to do' );
    $tira->tasklist_add( project => $root, text => 'something else' );

    my $summary = $tira->outstanding_summary( project => $root );
    is( $summary->{tasks}, 2, 'the tasks total still counts pending and working items' );
}

# --- every summary count applies the same rule -----------------------------
#
# CHK-005, and the reason this card is not a one-line fix. A total that
# excludes discarded work in one half and includes it in the other is the same
# fault wearing a different number.

{
    my $engine = Suite::engine_source();
    # non-empty is the whole claim: the checks below would pass on an
    # unreadable engine's emptiness alone.
    like( $engine, qr/\S/, 'the engine source is there to be read' );

    my ($summary) = $engine =~ /(sub \s+ outstanding_summary \b .*?\n\})/xs;
    like( $summary // '', qr/record_list/,
        'outstanding_summary was found, and is the one that walks the board' );
    like( $summary // '', qr/discard/,
        'and it says something about discard - a total that claims to match a view which '
          . 'excludes set-aside work has to make that exclusion somewhere' );
}

done_testing();

__END__

=head1 NAME

578-a-total-that-counts-work-set-aside.t - the outstanding total counts what the dashboard header counts

=head1 DESCRIPTION

TKT-827. C<tira.outstanding> is documented as answering the same project-wide
totals as the browser dashboard's sticky header, and it did not: C<record_list>
never mentions discard, so C<outstanding_summary> walked every column including
C<discard>, while C<dashboard> excludes that column explicitly. A card set aside
with an unanswered question on it was counted by one and not the other.

The difference only shows when a discarded card happens to carry an unanswered
question, which is why it went unnoticed - measured on the real board, 964
cards of which 165 were discarded, all 964 walked.

=cut
