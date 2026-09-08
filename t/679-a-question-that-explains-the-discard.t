#!/usr/bin/env perl
# TKT-679. discard-with-open-questions fires on ANY unanswered question a
# discarded card carries - including one asked AFTER the discard, about
# the discard itself. That is discard-unexplained's own remedy: the board
# has a standing rule that a decision question goes on the card via
# tira.question.ask rather than a popup, so asking the owner why he set a
# card aside is the correct, board-sanctioned move - and it made this
# rule fire too, leaving no compliant move on a card whose reason is not
# the agent's to invent.
#
# The fix: a question asked before the card entered its ending column is
# leftover work, exactly what this rule was written to catch. A question
# asked at or after is about the ending itself, and does not count.
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
my $now = '2026-09-08T10:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Explained', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'EXS', epic_prefix => 'EXE', ticket_prefix => 'EXT',
);
$tira->policy_add( project => $root, rule => 'discard-with-open-questions', action => 'log-only' );

sub reported {
    my $pass = $tira->police_pass( project => $root, store => $store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    return [ grep { $_->{rule} eq 'discard-with-open-questions' } @{ $pass->{violations} } ];
}

# --- leftover work: a question asked BEFORE the discard still fires ---------

my $leftover = $tira->create_record( project => $root, type => 'ticket', title => 'Leftover work' )->{ref};
$tira->question_add( project => $root, ref => $leftover, author => 'claude',
    text => 'Which way should this go?', reason => 'A real design question, unresolved' );
$now = '2026-09-08T10:05:00Z';
$tira->record_discard( author => 'claude', project => $root, ref => $leftover, reason => 'not worth doing' );

my @found = @{ reported() };
is( scalar @found, 1, 'a question asked before the discard is still reported as leftover work' );
is( $found[0]{ref}, $leftover, 'naming the right card' );

# --- explaining the discard: a question asked AFTER does not fire -----------

$now = '2026-09-08T10:10:00Z';
my $explained = $tira->create_record( project => $root, type => 'ticket', title => 'Explains itself' )->{ref};
$now = '2026-09-08T10:15:00Z';
$tira->record_discard( author => 'claude', project => $root, ref => $explained, reason => 'set aside for now' );
$now = '2026-09-08T10:16:00Z';
$tira->question_add( project => $root, ref => $explained, author => 'claude',
    text => 'Why was this set aside?', reason => 'The owner discarded it - asking rather than inventing a reason' );

is( scalar @{ reported() }, 1,
    'a question asked after the discard, about the discard, does not add a second finding' );
is( ( grep { $_->{ref} eq $explained } @{ reported() } ), 0,
    'the explaining card itself is not reported' );

done_testing();

__END__

=head1 NAME

679-a-question-that-explains-the-discard.t - discard-with-open-questions
does not fire on a question asked to explain the discard itself

=head1 DESCRIPTION

TKT-679. Compares a question's C<asked_at> against the timestamp the
card actually entered its ending column (read from the same history the
card's own C<discard-unexplained> comparison already uses). A question
raised before that move is leftover work and still fires; one raised at
or after is the board's own C<discard-unexplained> remedy being obeyed,
and no longer trips this rule.

=cut
