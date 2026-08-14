#!/usr/bin/env perl
# Every violation police raises is one the board can answer.
#
# Found by the hourly hunt, probing a class this codebase keeps rewarding from
# one side: a check that exists and never fires. This is the same failure seen
# from the other side - a check that fires and cannot be stopped.
#
# card-unreadable shipped in 1.78 and card-damaged in 1.80. Both are violations
# police raises, and neither is in the rule catalogue, so on a scratch board:
#
#     rule.suspend   --rule card-damaged   Unknown policy rule 'card-damaged'
#     policy.decline --rule card-damaged   Unknown policy rule 'card-damaged'
#     policy.undeclared                    26 rules, neither of them listed
#     rule.suspend   --rule card-stalled   accepted
#
# Two copies of one decision that drifted: what counts as a rule. The catalogue
# holds twenty-six, police raises twenty-eight, and the two extra were pushed
# straight into police_pass rather than declared - so every mechanism that reads
# the catalogue is blind to them.
#
# There is a second half, and it is the one that would have survived a careless
# fix. Those two are assembled in police_pass rather than reported through the
# rule loop, so they never pass the suspension check at all. Teaching the
# command to accept the name without teaching the pass to honour it would give
# an agent a suspension that reports success and changes nothing, which is worse
# than the refusal it replaced.
#
# It matters to him now rather than in principle. His board has two permanently
# damaged cards and he is not repairing those files until the repair command
# exists, so card-damaged reports there for ever. The quiet ladder makes it rare
# and never stops it, and putting a rule down for a while with a reason is
# exactly the escape hatch he asked for and had built.
#
# What must NOT change: a board that has answered neither still hears about a
# damaged card. Silence about corruption is the fault this whole thread began
# with, and a fix that made damage quiet by default would close the circle
# badly.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );

# Two instants, because a suspension is only interesting if it can be waited
# out - the second clock is past the end of a sixty-second putting-down.
my $now = '2026-08-15T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Answerable', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'ANS', epic_prefix => 'ANE', ticket_prefix => 'ANT',
);
$tira->policy_add( project => $root, rule => 'column-skipped',
    enter => 'verify', require => 'implement', action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Damaged, and skipping verify' )->{ref};
$tira->record_move( project => $root, ref => $card, column => 'verify' );

my $journal = File::Spec->catfile( $root, '.tira', 'history', "$card.jsonl" );
open my $damage, '>>:raw', $journal or die $!;
print {$damage} qq({"after":"Workflow finder \xd72","at":"2026-08-15T09:00:00Z",)
  . qq("author":null,"before":null,"field":"title","op":"update","ref":"$card"}\n);
close $damage;

sub world { return { branches => [], worktrees => [], processes => [], containers => [] } }

sub damaged_in {
    my ($store) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store, world => world() );
    return scalar grep { $_->{rule} eq 'card-damaged' } @{ $pass->{violations} };
}

# --- a board that has answered nothing still hears about it -------------------------
#
# First, because everything below is about silencing this and the one thing
# that must never happen is damage going quiet by default.

{
    my $store = File::Spec->catdir( $tmp, 'default' );
    is( damaged_in($store), 1,
        'a board that has neither suspended nor declined it is told its card is damaged' );
}

# --- and it can be put down, like every other rule ------------------------------------

{
    my $store = File::Spec->catdir( $tmp, 'suspended' );
    is( damaged_in($store), 1, 'reported before anything is asked for' );

    ok( eval {
            $tira->rule_suspend( store => $store, rule => 'card-damaged',
                seconds => 60, reason => 'the repair command does not exist yet' );
            1;
        },
        'the rule can be put down for a while, with a reason' ) or diag($@);

    is( damaged_in($store), 0, 'and it goes quiet' );

    # The half a careless fix would miss: these violations are assembled outside
    # the rule loop, so accepting the name without honouring it would report
    # success and change nothing.
    my $was = $now;
    $now = '2026-08-15T09:05:00Z';
    is( damaged_in($store), 1, 'and comes back by itself when the time runs out' );
    $now = $was;
}

# --- and refused outright, with a reason ----------------------------------------------

{
    my $store = File::Spec->catdir( $tmp, 'declined' );
    is( damaged_in($store), 1, 'reported before it is refused' );

    ok( eval {
            $tira->policy_decline( project => $root, rule => 'card-damaged',
                reason => 'these files are known bad and will not be repaired' );
            1;
        },
        'the rule can be declined, with a reason' ) or diag($@);

    is( damaged_in($store), 0, 'and says nothing afterwards' );

    like( join( ' ', map { $_->{rule} // '' } @{ $tira->policy_declined( project => $root ) } ),
        qr/card-damaged/, 'and the refusal is on the record with everything else' );
}

# --- while a reason is still compulsory --------------------------------------------------
#
# The rule that makes declining a decision rather than a way of going quiet
# applies to these exactly as it does to the rest.

ok( !eval {
        $tira->policy_decline( project => $root, rule => 'card-unreadable', reason => '' );
        1;
    },
    'declining one without a reason is refused, like any other rule' );

ok( !eval {
        $tira->rule_suspend( store => File::Spec->catdir( $tmp, 'nope' ),
            rule => 'card-unreadable', seconds => 60 );
        1;
    },
    'and putting one down without a reason is refused too' );

# --- but they are still not things a board declares ----------------------------------------
#
# They are not policies. They report whether policing was possible at all, so
# there is nothing to configure and nothing to scope, and the prompt must not
# start asking a board to declare two rules it cannot declare.

ok( !eval {
        $tira->policy_add( project => $root, rule => 'card-damaged',
            action => 'bridge-reminder' );
        1;
    },
    'neither can be declared as a policy, because there is nothing to configure' );

my $undeclared = $tira->policy_undeclared( project => $root );
is( scalar( grep { /\Acard-(?:damaged|unreadable)\z/ } @{$undeclared} ), 0,
    'and neither appears among the rules a board has not decided about' );

# --- the name in the refusal is still useful -----------------------------------------------
#
# A rule that genuinely does not exist must still be refused, and the message
# has to list something a reader can choose from.

my $unknown = !eval { $tira->rule_suspend( store => File::Spec->catdir( $tmp, 'x' ),
        rule => 'card-invented', seconds => 60, reason => 'probe' ); 1 };
ok( $unknown, 'a rule nobody has heard of is still refused' );
like( $@, qr/card-damaged/,
    'and the list it offers now includes the ones police can actually raise' );

done_testing;

__END__

=head1 NAME

174-a-rule-you-cannot-put-down.t - every violation police raises can be answered

=head1 DESCRIPTION

C<card-unreadable> and C<card-damaged> are violations police raises that were
not in the rule catalogue, so they could not be suspended, declined, or listed
among the rules a board has not decided about - while every other rule could.
Found by the hourly hunt: a check that fires and cannot be stopped, which is the
mirror of a check that never fires.

Both can now be put down for a period with a reason and declined outright, and
the pass honours both - they are assembled outside the rule loop, so accepting
the name without honouring it would have given an agent a suspension that
reported success and changed nothing.

Neither is declarable as a policy, because there is nothing to configure, and a
board that has answered neither is still told when a card is damaged.

=cut
