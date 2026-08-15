#!/usr/bin/env perl
# Police says it is watching, even when there is nothing left to set up.
#
# The prompt exists because silence looks exactly like compliance: a board
# nobody has configured produces no violations, and that reads as a board with
# nothing wrong. The CLI prints it under a comment saying it is "printed on
# every run, because remembering which run was the first is the sort of thing he
# should not have to do".
#
# It was not printed on every run. police_prompt returned undef the moment a
# board had declared its policies and had no rule left undeclared, so a fully
# configured board got nothing at all - and nothing is what a board gets when
# police has died, when it cannot read the project, and when it was never
# started. The owner reported it as police saying nothing after a restart; the
# board in question had thirty policies declared and none outstanding.
#
# So the two halves disagreed: the comment promised every run, the engine
# stopped once the work was done. This is the case that had no words.
#
# The other two are asserted here as well, because a line that appears for every
# board says nothing about any of them - the point is that each state is
# distinguishable from the others, and from silence.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-15T16:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'settled' );
$tira->project_new(
    name => 'Settled', dir => $root, members => ['michael'],
    columns => ['backlog, implement, done'],
);

# Nothing declared at all: the board is told what enforcement is for.
my $fresh = $tira->police_prompt( project => $root );
like( $fresh, qr/empty rulebook/,
    'a board with nothing declared is told that silence is not compliance' );

# One rule declared, the rest still outstanding: it is told which.
$tira->policy_add(
    project => $root, rule => 'card-unassigned', action => 'bridge-reminder',
);
my $behind = $tira->police_prompt( project => $root );
like( $behind, qr/not using/,
    'a board part way through is told which rules it has not declared' );

# Every remaining rule answered - declared above, or declined here with a
# reason. This is the state the owner's board was in.
for my $rule ( @{ $tira->policy_undeclared( project => $root ) } ) {
    $tira->policy_decline(
        project => $root, rule => $rule,
        reason  => 'not how this project works',
    );
}

is( scalar @{ $tira->policy_undeclared( project => $root ) }, 0,
    'the board now has no rule left unanswered' );

my $settled = $tira->police_prompt( project => $root );

ok( defined $settled && $settled =~ /\S/,
    'and police still says something, rather than going silent for ever' );

like(
    $settled,
    qr/watching/i,
    'it says it is watching, so silence never means the same as police having died'
);

unlike(
    $settled,
    qr/empty rulebook|not using/,
    'and it does not repeat the setup instructions to a board that has finished'
);

done_testing;

__END__

=head1 NAME

206-a-board-that-has-finished-setting-up.t - watching, and saying so

=head1 DESCRIPTION

C<police_prompt> returned undef once a board had declared its policies with no
rule left undeclared, while the CLI that prints it carried a comment promising
it on every run. A fully configured board therefore said nothing, which is what
a board also says when police has died or was never started.

The owner reported it as police being silent after a restart. The board had
thirty policies declared and none outstanding, and so did the Tira development
board - which is why it looked project-specific.

All three states are asserted, because the point is that each can be told apart
from the others and from silence.

=cut
