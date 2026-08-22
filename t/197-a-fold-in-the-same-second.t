#!/usr/bin/env perl
# A fold written in the same second as the mark is a fold.
#
# Reported from mt5-ai on 2026-08-15, with the discriminator isolated by
# comparing three cards rather than by reasoning about one. The same script made
# the same two calls in the same order for all three:
#
#     M5T-394  marked 10:40:20  card written 10:40:21   silent
#     M5T-388  marked 10:42:33  card written 10:42:34   silent
#     M5T-372  marked 10:44:32  card written 10:44:32   VIOLATION
#
# The one that fired is the one where the stamps are equal. Timestamps here are
# second-resolution, so a fold written inside the same second as the mark cannot
# produce a strictly later stamp, and the rule asked for strictly later.
#
# Their sentence about why it is worth fixing is the one that sets the priority:
# an agent that marks and folds in one script - which is the correct thing to do
# and exactly what this rule asks for - lands in the same second whenever the
# board is quick. So the agents that behave best are the ones most likely to be
# told they did not.
#
# And it is unfalsifiable from the outside. The message says nothing was written
# down while the thing is written down, so the obvious response is to write it
# again, which changes nothing until a second happens to elapse. They only found
# it by comparing all three; from any one card it looks like the rule being
# right.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );

# One instant, held still. The whole report is about what happens when two
# writes land in the same second, so the clock must not move between them -
# a test that let it move would pass without ever reaching the case.
my $now = '2026-08-15T10:44:32Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Folding', dir => $root, members => [ 'claude', 'michael' ],
    columns => ['backlog, done'],
    sow_prefix => 'FLS', epic_prefix => 'FLE', ticket_prefix => 'FLT',
);
$tira->policy_add( project => $root, rule => 'answer-ok-not-folded',
    age => '10m', action => 'bridge-reminder' );

# Set up in an earlier second than the mark, deliberately. Holding the clock
# still through the card's own creation made its title write land in the same
# second as the mark, which counts as a detail change and made even the bare
# card look folded - the test failed and was right to. The reported case is a
# card that already exists and is then marked and folded in one second, so that
# is what this builds.
sub asked_and_answered {
    my ($title) = @_;
    my $before = $now;
    $now = '2026-08-15T10:30:00Z';
    my $ref = $tira->create_record( project => $root, type => 'ticket',
        title => $title )->{ref};
    my $question = $tira->question_add( project => $root, ref => $ref,
        author => 'claude', text => 'Which way round is it?' );
    $tira->question_answer( project => $root, id => $question->{id},
        text => 'That way round' );
    $now = $before;
    return ( $ref, $question->{id} );
}

sub reported {
    my ($store) = @_;
    my $pass = $tira->police_pass( project => $root,
        store => File::Spec->catdir( $tmp, $store ),
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    return [ grep { $_->{rule} eq 'answer-ok-not-folded' } @{ $pass->{violations} } ];
}

# --- marked and folded in the same second, which is what their script does ------------

my ( $card, $question ) = asked_and_answered('Marked and folded together');
$tira->question_mark( project => $root, id => $question, mark => 'ok', author => 'claude' );
$tira->record_update( author => 'claude', project => $root, ref => $card,
    key_details => ["$question was answered: that way round"] );

# Ten minutes on, so the age has passed and the rule is entitled to speak.
$now = '2026-08-15T10:55:00Z';
is_deeply( reported('together'), [],
    'a fold written in the same second as the mark counts as folded' );

# --- while a card nobody folded into is still reported ----------------------------------
#
# The half that matters more than the fix: a rule that accepted everything would
# be worse than one that accuses the diligent, because nothing would be asked of
# anybody.

{
    $now = '2026-08-15T10:44:32Z';
    my ( $bare, $unfolded ) = asked_and_answered('Marked and left alone');
    $tira->question_mark( project => $root, id => $unfolded, mark => 'ok', author => 'claude' );

    $now = '2026-08-15T10:55:00Z';
    my $found = reported('bare');
    is( scalar( grep { $_->{ref} eq $bare } @{$found} ), 1,
        'a card marked ok with nothing written into it is still reported' );
}

# --- and a detail written before the mark is not a fold ------------------------------------
#
# The edge the comparison gives up. Writing a field and then marking the answer
# ok, seconds apart, is not folding the answer in - and it must not read as one,
# or the rule stops meaning anything.

{
    $now = '2026-08-15T11:00:00Z';
    my ( $early, $late ) = asked_and_answered('Written first, marked after');
    $tira->record_update( author => 'claude', project => $root, ref => $early,
        key_details => ['Something unrelated, written before the answer was judged'] );

    $now = '2026-08-15T11:00:30Z';
    $tira->question_mark( project => $root, id => $late, mark => 'ok', author => 'claude' );

    $now = '2026-08-15T11:20:00Z';
    my $found = reported('early');
    is( scalar( grep { $_->{ref} eq $early } @{$found} ), 1,
        'a detail written before the mark is not a fold of it' );
}

done_testing;

__END__

=head1 NAME

197-a-fold-in-the-same-second.t - marking and folding together is folding

=head1 DESCRIPTION

C<answer-ok-not-folded> asked for a detail field written strictly later than the
mark. At second resolution a fold written inside the same second cannot be
strictly later, so an agent that marks and folds in one script - the correct
thing, and what the rule asks for - was told it had not folded, on a board quick
enough to do both in one second.

The comparison is now at-or-after. A card with nothing written into it is still
reported, and a detail written in an earlier second than the mark is still not a
fold of it.

=cut
