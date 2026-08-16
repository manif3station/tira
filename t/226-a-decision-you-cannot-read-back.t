#!/usr/bin/env perl
# A decision you cannot read back was not recorded.
#
# Reported from another project on 2.07 and reproduced three times: with
# column-unwatched declared, declining it returns a timestamp and the rule name
# and exits zero, and reading the declines back afterwards shows nothing.
#
# It is stored. The reader is what hides it: policy_declined filters out any
# rule that is currently declared, which is right for its own purpose -
# declaring a rule later clears the note saying it was declined, because a
# project that changed its mind should not carry a record saying the opposite.
# t/117 holds that and it stays.
#
# What is wrong is the answer. Declining a rule that is declared is a
# contradiction, and the two ways to treat a contradiction are to refuse it or
# to resolve it. Answering with a stored decision that cannot be read back is
# the third thing, and it is the one answer nobody can act on: the caller is
# told the decision was recorded, and it was not - not in any sense they can
# check.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Decided', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'DDS', epic_prefix => 'DDE', ticket_prefix => 'DDT',
);

$tira->policy_add( project => $root, rule => 'card-unassigned', action => 'bridge-reminder' );

# --- declining a rule the project is using ---------------------------------

my $refused = !eval {
    $tira->policy_decline( project => $root, rule => 'card-unassigned',
        reason => 'we decided against it after all' );
    1;
};
my $said = $@;

# Asserted on $@ itself, before anything else runs and clears it. A copy is
# what the next assertion reads, and a copy can be of the wrong thing - which
# is what t/149 exists to catch, and it caught this file.
like( $@, qr/card-unassigned/, 'the refusal names the rule, which is what the caller has to act on' );

ok( $refused, 'declining a rule the project is using is refused' );

# non-empty is the whole claim: a precondition for the assertion below, which
# would pass against a refusal that said nothing at all.
like( $said, qr/\S/, 'and says something about it' );
like( $said, qr/declared|using|remove/i,
    'and why, so the caller knows the rule has to be removed first' );

# --- and the board is as it was --------------------------------------------
#
# The whole complaint was an answer that could not be read back. A refusal that
# quietly wrote something would be the same fault wearing the other face.

# Asked of what was stored, not of the reader. policy_declined hides declines
# for rules that are declared, so it answers "none" whether the refusal worked
# or whether the entry was written and hidden - which is the fault itself, and
# an assertion that cannot tell those apart proves nothing about either. Found
# by removing the refusal and watching this pass anyway.
is( scalar @{ $tira->project_show( project => $root )->{declined_policies} // [] }, 0,
    'nothing was written, which is what a refusal means' );
is( scalar( grep { ( $_->{rule} // '' ) eq 'card-unassigned' }
        @{ $tira->policy_list( project => $root ) } ),
    1, 'and the rule is still declared, untouched' );

# --- a rule nobody declared is still declinable ------------------------------

my $declined = $tira->policy_decline( project => $root, rule => 'wip-limit',
    reason => 'nothing here needs a limit on one column' );
is( $declined->{rule}, 'wip-limit', 'a rule the project is not using can be declined' );
is( scalar @{ $tira->policy_declined( project => $root ) }, 1,
    'and read back afterwards, which is the whole of what was missing' );

# --- and declaring one still clears its declining ---------------------------
#
# The behaviour that made the reader filter in the first place. It stays.

$tira->policy_add( project => $root, rule => 'wip-limit',
    column => 'implement', max => 1, action => 'bridge-reminder' );
is( scalar @{ $tira->policy_declined( project => $root ) }, 0,
    'declaring a rule still clears the note saying it was declined' );

done_testing;

__END__

=head1 NAME

226-a-decision-you-cannot-read-back.t - refused, or done, but not neither

=head1 DESCRIPTION

Declining a rule the project is using returned a timestamp and stored something
the reader would never show, because C<policy_declined> hides declines for
rules that are declared - which is right, and is how declaring a rule clears
its declining.

The answer was the fault. A contradiction is refused or resolved; answering
with a decision that cannot be read back is the one result nobody can act on.

=cut
