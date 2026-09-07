#!/usr/bin/env perl
# TKT-989, his report on DD-810. answer-not-ok-no-followup's cross-branch
# accepted a follow-up only when it was ASKED strictly after the not-ok
# mark. Asking the replacement question first and crossing the old one
# second - the diligent ordering, since it never leaves the card with an
# unpaired cross even for a moment - fired this rule forever, because the
# follow-up's own asked_at came before the mark it was meant to answer.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

sub new_board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $now  = '2026-09-07T03:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Watched', dir => $root, members => [ 'michael', 'claude' ],
        columns => ['backlog, implement, verify, done'],
    );
    $tira->policy_add( project => $root, rule => 'answer-not-ok-no-followup', age => '10m', action => 'bridge-reminder' );
    return ( $tira, $root, sub { $now = $_[0]; return $now } );
}

sub fired {
    my ( $tira, $root ) = @_;
    my $result = $tira->policy_evaluate( project => $root );
    return grep { $_->{rule} eq 'answer-not-ok-no-followup' } @{$result};
}

# --- his exact DD-810 sequence: ask, THEN mark, then answer -----------------

{
    my ( $tira, $root, $at ) = new_board();
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'DD-810' );

    $at->('2026-09-07T03:35:00Z');
    my $crossed = $tira->question_add( project => $root, ref => $card->{ref},
        author => 'claude', text => 'Which reading is right?' );

    $at->('2026-09-07T03:35:23Z');
    my $followup = $tira->question_add( project => $root, ref => $card->{ref},
        author => 'claude', text => 'Or did you mean the other one?' );

    $at->('2026-09-07T03:36:03Z');
    $tira->question_answer( project => $root, ref => $card->{ref}, id => $crossed->{id}, text => 'Neither' );
    $tira->question_mark( project => $root, ref => $card->{ref}, id => $crossed->{id}, mark => 'not-ok' );

    $at->('2026-09-07T03:36:18Z');
    $tira->question_answer( project => $root, ref => $card->{ref}, id => $followup->{id}, text => 'The second one' );

    $at->('2026-09-07T03:38:24Z');
    $tira->question_mark( project => $root, ref => $card->{ref}, id => $followup->{id}, mark => 'ok' );

    $at->('2026-09-07T03:50:00Z');
    is( scalar fired( $tira, $root ), 0,
        'a follow-up asked BEFORE the mark, then answered and judged after it, settles the finding' );
}

# --- no follow-up at all: the rule still fires ------------------------------

{
    my ( $tira, $root, $at ) = new_board();
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'No follow-up' );

    $at->('2026-09-07T04:00:00Z');
    my $lonely = $tira->question_add( project => $root, ref => $card->{ref},
        author => 'claude', text => 'Which way?' );
    $at->('2026-09-07T04:01:00Z');
    $tira->question_answer( project => $root, ref => $card->{ref}, id => $lonely->{id}, text => 'no' );
    $tira->question_mark( project => $root, ref => $card->{ref}, id => $lonely->{id}, mark => 'not-ok' );

    $at->('2026-09-07T04:15:00Z');
    is( scalar fired( $tira, $root ), 1, 'a genuine cross with nothing else on the card still fires' );
}

# --- an unrelated question, asked and resolved well before the mark, does
# not retroactively count as a follow-up -------------------------------------

{
    my ( $tira, $root, $at ) = new_board();
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Old unrelated question' );

    $at->('2026-09-07T05:00:00Z');
    my $old = $tira->question_add( project => $root, ref => $card->{ref},
        author => 'claude', text => 'Some earlier, unrelated question' );
    $at->('2026-09-07T05:01:00Z');
    $tira->question_answer( project => $root, ref => $card->{ref}, id => $old->{id}, text => 'yes' );
    $tira->question_mark( project => $root, ref => $card->{ref}, id => $old->{id}, mark => 'ok' );

    $at->('2026-09-07T05:30:00Z');
    my $crossed = $tira->question_add( project => $root, ref => $card->{ref},
        author => 'claude', text => 'A different, later question' );
    $tira->question_answer( project => $root, ref => $card->{ref}, id => $crossed->{id}, text => 'no' );
    $tira->question_mark( project => $root, ref => $card->{ref}, id => $crossed->{id}, mark => 'not-ok' );

    $at->('2026-09-07T05:45:00Z');
    is( scalar fired( $tira, $root ), 1,
        'an old, already-resolved unrelated question does not count as this cross own follow-up' );
}

# --- the existing working case: asked after the mark, unchanged ------------

{
    my ( $tira, $root, $at ) = new_board();
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Asked after' );

    $at->('2026-09-07T06:00:00Z');
    my $crossed = $tira->question_add( project => $root, ref => $card->{ref},
        author => 'claude', text => 'Which one?' );
    $tira->question_answer( project => $root, ref => $card->{ref}, id => $crossed->{id}, text => 'no' );
    $tira->question_mark( project => $root, ref => $card->{ref}, id => $crossed->{id}, mark => 'not-ok' );

    $at->('2026-09-07T06:15:00Z');
    $tira->question_add( project => $root, ref => $card->{ref}, author => 'claude', text => 'Then which?' );
    is( scalar fired( $tira, $root ), 0, 'a follow-up asked after the mark still silences it, unchanged' );
}

done_testing();

__END__

=head1 NAME

600-a-follow-up-asked-before-it-had-to-be.t - answer-not-ok-no-followup and the
diligent ask-then-mark ordering

=head1 DESCRIPTION

TKT-989, his report on DD-810. C<answer-not-ok-no-followup>'s cross-branch
required a follow-up question's own C<asked_at> to be strictly later than the
not-ok mark - so asking the replacement first and crossing the old question
second, the ordering that never leaves a card with an unpaired cross even for
a moment, fired this rule forever even once that follow-up was answered and
judged.

A follow-up now counts if it was either asked after the mark (unchanged) or
its own answer was resolved (C<marked_at>/C<answered_at>) after the mark,
whichever order it was asked in - resolved-after, not a time window or a
reference match. An old, already-settled, unrelated question does not
retroactively count just by existing on the same card.

=cut
