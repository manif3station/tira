#!/usr/bin/env perl
# A card held on an unanswered question is not offered as the next thing to work.
#
# Reported by Zenandi the hour tira.next landed, and their account of it is
# careful enough to be worth keeping: the command is not wrong. It answered
# ZOW-1 - a SOW under a standing order from Michael, "keep them at the backlog
# and i want to check for alignment first, do not start working" - and ZOW-1 is
# in backlog, carries priority 5, and has waited longest. Given what the command
# could see, that is the right answer.
#
# What it could not see is the hold. They measured that too: ZOW-1 records it in
# seven of its eighty key_details, every one prose, and they read the whole field
# list looking for somewhere better to put it.
#
# There is somewhere better, and it is not a new field. priority-skipped has
# refused to name a card as passed over while it carries an unanswered question
# since that rule was written - "parked, not skipped", in its own comment. A
# question is a hold a tool can read: it names the condition, and the answer
# arriving is the release trigger.
#
# So the gap is not that a hold cannot be recorded. It is that work_order does
# not read the one that can be - which is the TKT-274 shape again, in the half
# nobody looked at: the rule parks a card and the command offers it, about the
# same board, at the same moment.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-17T09:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Parked', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'PKS', epic_prefix => 'PKE', ticket_prefix => 'PKT',
);
$tira->policy_add( project => $root, rule => 'priority-skipped',
    action => 'bridge-reminder' );

my $held = $tira->create_record( project => $root, type => 'ticket',
    title => 'Held until he checks the alignment', priority => 5 );
$now = '2026-08-17T10:00:00Z';
my $free = $tira->create_record( project => $root, type => 'ticket',
    title => 'Nothing is holding this one', priority => 4 );

# --- before the hold, it is the answer -----------------------------------------

is( $tira->work_order( project => $root )->[0]{ref}, $held->{ref},
    'the top card is the answer while nothing is holding it' );

# --- and once it is held, it is not --------------------------------------------

my $question = $tira->question_add( project => $root, ref => $held->{ref},
    text  => 'Is this aligned with what you want built before it starts?',
    reason => 'Standing order: it stays in the backlog until he has checked.' );

{
    my $order = $tira->work_order( project => $root );

    is( $order->[0]{ref}, $free->{ref},
        'the answer is the highest card that is not held' );

    my %offered = map { $_->{ref} => 1 } @{$order};
    ok( !$offered{ $held->{ref} },
        'and the held card is not offered anywhere, rather than offered further down' );
}

# --- which is what the rule has always done ------------------------------------
#
# The agreement is the point. The rule parked this card and the command offered
# it, about the same board at the same moment, which is the disagreement
# work_order exists to make impossible.

{
    $tira->record_move( project => $root, ref => $free->{ref}, column => 'implement' );

    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    my @skipped = grep { ( $_->{rule} // '' ) eq 'priority-skipped' }
      @{ $pass->{violations} };

    is_deeply( [ map { $_->{detail} } @skipped ], [],
        'the rule does not report the lower card as skipping a held one, and never did' );
}

# --- and answering it releases the card ----------------------------------------
#
# A hold that cannot be lifted is a discard with extra steps. The answer
# arriving is the release trigger, which is the half their process keeps in
# prose today.

{
    $tira->question_answer( project => $root, ref => $held->{ref},
        id => $question->{id}, text => 'Yes - aligned, start it.',
        author => 'claude' );

    my $order = $tira->work_order( project => $root );
    is( $order->[0]{ref}, $held->{ref},
        'answering the question puts the card back at the top' );
    is( scalar @{$order}, 1,
        'and the other card is not offered, because it is being worked - so nothing else changed' );
}

# --- proved by not asking ------------------------------------------------------
#
# With the question ignored, the held card is the answer again, which is what
# Zenandi got: the command offering work under an explicit order not to start it.

{
    no warnings 'redefine';
    local *Tira::_policy_questions = sub { return () };

    $tira->question_add( project => $root, ref => $held->{ref},
        text  => 'Held again, and this time nothing reads it',
        reason => 'The state that was reported.' );

    is( $tira->work_order( project => $root )->[0]{ref}, $held->{ref},
        'a hold nothing reads is a hold nothing honours' );
}

done_testing;

__END__

=head1 NAME

255-a-card-that-is-parked.t - a hold the board can read, honoured where it counts

=head1 DESCRIPTION

C<tira.next> offered a card under an explicit standing order not to be worked.
The hold was real and recorded - in prose, across seven key_details - and
nothing could read it.

A hold a tool can read already exists: C<priority-skipped> has refused to name a
card carrying an unanswered question since it was written. C<work_order> did not
ask, so the rule parked a card while the command offered it. It asks now.

=cut
