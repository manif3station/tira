#!/usr/bin/env perl
# Having read an answer removes the excuse for not judging it.
#
# answer-unjudged waits the same age for an answer nobody has opened and one
# that was read ten minutes ago. Those are not the same thing, and the record
# already knows the difference: every answer carries read_at as well as
# answered_at.
#
# It came from a real miss. His four answers on TKT-106 landed at 09:36, they
# were read at 09:40, all four were folded into the card, and the marks were
# left off until he asked at 09:43 - inside a two-hour grace, so police was
# right to be silent, and the silence was still covering a job half done. He was
# offered the sharpening and said: do it.
#
# One rule with two ages rather than a second rule that means almost the same
# thing. Two rules firing on nearly the same condition is how a bridge becomes
# noise, which is the fault TKT-099 was raised for a day earlier.
#
# The second age is optional, so a board that gives one age behaves exactly as
# it does today and nothing changes meaning under anybody on upgrade.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-13T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Judged', dir => $root, members => [ 'michael', 'ada' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'JGS', epic_prefix => 'JGE', ticket_prefix => 'JGT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Waiting on a judgement' );
my $question = $tira->question_add( project => $root, ref => $card->{ref},
    author => 'ada', text => 'Which way?', reason => 'both work' );

sub unjudged {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    my ($found) = grep { $_->{rule} eq 'answer-unjudged' } @{ $pass->{violations} };
    return $found;
}

# Two hours to notice at all, ten minutes once it has been read. The second is
# what this card adds.
$tira->policy_add( project => $root, rule => 'answer-unjudged',
    age => '2h', read_age => '10m', action => 'bridge-reminder' );

$now = '2026-08-13T09:01:00Z';
$tira->question_answer( project => $root, id => $question->{id},
    text => 'The first one', author => 'michael' );

# --- unopened, and inside the long age -----------------------------------------

$now = '2026-08-13T09:30:00Z';
ok( !unjudged(), 'an answer nobody has opened is not chased inside the long age' );

# --- read, and now inside the long age but past the short one -------------------
#
# The case that was missed. Half an hour after reading it, with two hours to run
# on the clock that was watching.

$now = '2026-08-13T09:35:00Z';
$tira->question_list( project => $root, ref => $card->{ref} );

$now = '2026-08-13T09:50:00Z';
my $chased = unjudged();
ok( $chased, 'an answer read fifteen minutes ago is chased, though the long age has an hour to run' );
like( $chased->{detail}, qr/\Q$question->{id}\E/, 'naming the question' );
like( $chased->{detail}, qr/read/i,
    'and saying it is being chased for not being judged rather than for not being noticed' );

# --- reading it does not restart anything ---------------------------------------
#
# Reading is recorded by reading, so a rule that reset on every read would be
# silenced by the very act it is chasing somebody past.

$now = '2026-08-13T09:51:00Z';
$tira->question_list( project => $root, ref => $card->{ref} );
$now = '2026-08-13T09:52:00Z';
ok( unjudged(), 'reading it again does not buy another grace' );

# --- and judging it stops both --------------------------------------------------

$now = '2026-08-13T09:53:00Z';
$tira->question_mark( project => $root, id => $question->{id}, mark => 'ok' );
$now = '2026-08-13T09:54:00Z';
ok( !unjudged(), 'a judged answer is chased by neither clock' );

# --- unopened still waits the long age ------------------------------------------
#
# Nothing here may make the original clock stricter. An answer nobody has
# opened is exactly the case the two-hour age was set for.

my $second = $tira->create_record( project => $root, type => 'ticket', title => 'Nobody has looked' );
my $unopened = $tira->question_add( project => $root, ref => $second->{ref},
    author => 'ada', text => 'And this one?', reason => 'also both work' );
$now = '2026-08-13T10:00:00Z';
$tira->question_answer( project => $root, id => $unopened->{id},
    text => 'The second one', author => 'michael' );

$now = '2026-08-13T11:00:00Z';
my ($still) = grep { $_->{ref} eq $second->{ref} } grep { defined }
  ( map { $_ } ( unjudged() // () ) );
ok( !$still, 'an hour on, an answer nobody has opened is still inside its two hours' );

$now = '2026-08-13T12:30:00Z';
ok( unjudged(), 'and past two hours it is chased, exactly as before' );

# --- a board that gives one age behaves as it always has -------------------------
#
# The upgrade promise. Nobody's existing policy changes meaning underneath them.

my $old_root = File::Spec->catdir( $tmp, 'old' );
$tira->project_new(
    name => 'As before', dir => $old_root, members => ['ada'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'OBS', epic_prefix => 'OBE', ticket_prefix => 'OBT',
);
my $old_store = File::Spec->catdir( $tmp, 'old-police' );
$tira->policy_add( project => $old_root, rule => 'answer-unjudged',
    age => '2h', action => 'bridge-reminder' );
my $old_card = $tira->create_record( project => $old_root, type => 'ticket', title => 'Old ways' );
my $old_question = $tira->question_add( project => $old_root, ref => $old_card->{ref},
    author => 'ada', text => 'Anything?', reason => 'because' );

$now = '2026-08-13T13:00:00Z';
$tira->question_answer( project => $old_root, id => $old_question->{id},
    text => 'Yes', author => 'michael' );
$now = '2026-08-13T13:05:00Z';
$tira->question_list( project => $old_root, ref => $old_card->{ref} );

$now = '2026-08-13T13:30:00Z';
my $old_pass = $tira->police_pass( project => $old_root, store => $old_store, world => {} );
is( scalar( grep { $_->{rule} eq 'answer-unjudged' } @{ $old_pass->{violations} } ), 0,
    'a policy with one age is silent half an hour after a read, exactly as it was' );

# --- and a shorter age longer than the first is refused --------------------------
#
# A second grace that outlasts the first says nothing and would be believed. The
# machinery for refusing a setting a rule cannot honour is already here.

my $refused = !eval {
    $tira->policy_add( project => $root, rule => 'answer-unjudged',
        age => '10m', read_age => '2h', action => 'bridge-reminder' );
    1;
};
ok( $refused, 'a read age longer than the age it shortens is refused rather than ignored' );

done_testing;

__END__

=head1 NAME

136-read-shortens-the-clock.t - having read an answer removes the excuse

=head1 DESCRIPTION

C<answer-unjudged> waited the same age for an answer nobody had opened and one
read ten minutes ago, though the record knows the difference. So an agent that
read four answers, acted on all of them and left the marks off had a two-hour
grace before anything said so.

The rule now takes an optional second age, counted from when the answer was
read. The first is unchanged, so a board giving one age behaves exactly as it
did; a read does not buy another grace; a judged answer is chased by neither;
and a second age longer than the first is refused rather than quietly ignored.

=cut
