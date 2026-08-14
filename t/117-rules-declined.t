#!/usr/bin/env perl
# Saying no to a rule, once, and not being asked again.
#
# police_prompt lists every rule a project has not declared, because a rule
# nobody declared is silent in exactly the way a rule being obeyed is. That is
# right, and it is why the prompt prints on every run rather than only the
# first - remembering which run was the first is the sort of thing the owner
# should not have to do.
#
# What it could not tell was "nobody has looked at this" from "somebody looked
# and said no". On a board mature enough to have made those decisions it asks a
# question that has already been answered, every run, indefinitely - and this
# codebase names what that does often enough: a channel that repeats itself is
# one everybody learns to read past, and this is the channel that exists to be
# read.
#
# The reason is required. A decision with no reason recorded is indistinguishable
# from having skipped the question, which is the thing this whole subsystem
# exists to remove.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T12:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Decided', dir => $root, members => ['michael'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'DCS', epic_prefix => 'DCE', ticket_prefix => 'DCT',
);

# One rule declared, so this is a project that has been set up and is behind -
# the case the prompt is really for.
$tira->policy_add( project => $root, rule => 'card-stalled',
    before => 'implement', action => 'bridge-reminder' );

# --- asked about, as it is today ------------------------------------------

my $asking = $tira->police_prompt( project => $root );
like( $asking, qr/card-sandbox-missing/, 'a rule nobody has looked at is asked about' );
like( $asking, qr/wip-limit/, 'and so is every other one' );

# --- said no, with a reason -----------------------------------------------

my $declined = $tira->policy_decline(
    project => $root, rule => 'card-sandbox-missing',
    reason => 'nothing here uses work trees, so it would fire on every card being worked',
);
is( $declined->{rule}, 'card-sandbox-missing', 'a rule can be considered and declined' );
like( $declined->{reason}, qr/work trees/, 'with the reason kept, not just the refusal' );
ok( $declined->{declined_at}, 'and when it was decided' );

my $quieter = $tira->police_prompt( project => $root );
unlike( $quieter, qr/card-sandbox-missing/, 'and the prompt stops asking about it' );
like( $quieter, qr/wip-limit/, 'while still asking about the ones nobody has answered' );

# --- a reason is not optional ---------------------------------------------

my $refused = !eval { $tira->policy_decline( project => $root, rule => 'wip-limit' ); 1 };
ok( $refused, 'declining with no reason is refused' );
like( $@, qr/reason/i, 'and says what is missing' );
like( $tira->police_prompt( project => $root ), qr/wip-limit/,
    'so the rule is still asked about, which is what should happen to a decision nobody made' );

my $empty = !eval {
    $tira->policy_decline( project => $root, rule => 'wip-limit', reason => '   ' );
    1;
};
ok( $empty, 'and neither is a reason made of spaces' );
like( $@, qr/needs a reason/, 'refused for the reason being empty' );

# --- a rule that does not exist -------------------------------------------

my $unknown = !eval {
    $tira->policy_decline( project => $root, rule => 'no-such-rule', reason => 'invented' );
    1;
};
ok( $unknown, 'a rule nobody has heard of cannot be declined' );
like( $@, qr/Unknown policy rule/, 'refused for the rule, and it lists the ones there are' );

# --- read back ------------------------------------------------------------
#
# On the board rather than in somebody's memory, which is the whole point.

my $decisions = $tira->policy_declined( project => $root );
is( scalar @{$decisions}, 1, 'the decisions can be read back' );
is( $decisions->[0]{rule}, 'card-sandbox-missing', 'naming the rule' );

# --- declaring it later clears the declining ------------------------------
#
# Otherwise a project that changed its mind would carry a record saying it had
# decided the opposite, which is worse than carrying nothing.

$tira->policy_add( project => $root, rule => 'card-sandbox-missing',
    enter => 'implement', sandbox => '/sandboxes', action => 'bridge-reminder' );
is( scalar @{ $tira->policy_declined( project => $root ) }, 0,
    'declaring a rule clears the note saying it was declined' );

# --- nothing left to say --------------------------------------------------
#
# Every rule either declared or declined: the prompt has nothing to ask, and
# says nothing rather than printing a heading with an empty list under it.

for my $rule ( @{ $tira->policy_rules } ) {
    next if grep { ( $_->{rule} // '' ) eq $rule } @{ $tira->policy_list( project => $root ) };
    $tira->policy_decline( project => $root, rule => $rule,
        reason => 'considered and not needed on this project' );
}
is( $tira->police_prompt( project => $root ), undef,
    'with every rule declared or declined, the prompt has nothing to say and says nothing' );

done_testing();

__END__

=head1 NAME

117-rules-declined.t - saying no to a rule once, and not being asked again

=head1 DESCRIPTION

The prompt lists rules a project has not declared, and prints on every run
because remembering which run was the first is not the owner's job. It could
not tell "nobody has looked at this" from "somebody looked and said no", so on
a board that has made those decisions it asked an answered question for ever.

A rule can now be declined with a reason. The reason is required: a decision
with none recorded is indistinguishable from having skipped the question.
Declaring a rule later clears its declining, and a rule that arrives in a
future release is asked about exactly as it is today.

=cut
