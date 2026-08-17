#!/usr/bin/env perl
# An upgrade is announced once, however many watchers there are.
#
# police records which version it has announced and compares it with its own.
# The comment above that guard says why: "once per version rather than once per
# start, because police restarts in order to pick a new version up, and a line
# written on every start would arrive on a loop for as long as nobody upgraded
# again."
#
# It compared for difference, and a difference has two directions. Two watchers
# at different versions each saw a value that was not theirs, announced an
# upgrade, and wrote their own - so the record flipped back and forth and the
# notice arrived for ever. Measured on this board on 2026-08-16 with five
# watchers running:
#
#     23:16:42  Tira is now 2.35 - this board last heard 2.34
#     23:16:51  Tira is now 2.34 - this board last heard 2.35
#
# Nine seconds apart, in opposite directions, and still going eight minutes
# later. The guard existed and could not hold.
#
# Not fixed with a lock: two watchers is the documented arrangement - police in
# the owner's terminal, a bridge the agent tails - and both run a pass.
#
# And not fixed by announcing only a newer version, which was the obvious thing
# and was wrong. t/175 asserts that a rollback is announced too, and its comment
# says that assertion was written after getting it the other way round: "the
# rules the agent learned about may not be there any more". Announcing forwards
# only would drop that silently.
#
# What changes is the record: what has been SAID, not merely what was last seen.
# A change from one version to another is news the first time and not the
# second, so two watchers taking turns say it twice and then stop for ever,
# while a move to something this board has not been told about is still news.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-16T23:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Announced', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ANS', epic_prefix => 'ANE', ticket_prefix => 'ANT',
);

# A declared policy, because a board with none is answered with advice about
# declaring some and never reaches the version notice at all - which is how the
# first version of this test measured nothing and looked like a finding.
$tira->policy_add( project => $root, rule => 'orphan-card', action => 'log-only' );

my $store = File::Spec->catdir( $tmp, 'police' );

# One watcher's pass, at whatever version that watcher is running.
sub pass_at {
    my ($version) = @_;
    no warnings 'redefine';
    local $Tira::VERSION = $version;
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return $pass->{upgraded};
}

# --- the first watcher to run says so ----------------------------------------

{
    my $said = pass_at('2.34');
    ok( $said, 'a board that has heard nothing is told which version it has' );
    is( $said->{to}, '2.34', 'naming the version that is running' );
}

# --- and does not say it again ------------------------------------------------

is( pass_at('2.34'), undef, 'the same watcher passing again says nothing' );

# --- a newer watcher says so once ---------------------------------------------

{
    my $said = pass_at('2.35');
    ok( $said, 'a watcher running a newer version announces the upgrade' );
    is( $said->{from}, '2.34', 'saying what the board last heard' );
    is( $said->{to},   '2.35', 'and what it is now' );
}

# --- the older watcher says it once, because it is a change nobody has heard ---
#
# Going back IS news the first time: the rules the agent learned about may not
# be there any more, which is what t/175 has asserted since before this card.

{
    my $said = pass_at('2.34');
    ok( $said, 'a watcher on the older version says so, once' );
    is( $said->{from}, '2.35', 'naming what the board had been told' );
}

is( pass_at('2.35'), undef, 'and going back the other way is not news twice' );
is( pass_at('2.34'), undef, 'nor is coming back again' );

# --- two watchers, alternating, as they actually run --------------------------
#
# The loop as it happened: two versions taking turns. Counted rather than
# described, because "it happens for ever" is the claim.

{
    my $announced = 0;
    for ( 1 .. 5 ) {
        $announced++ if pass_at('2.35');
        $announced++ if pass_at('2.34');
    }
    is( $announced, 0,
        'ten alternating passes after both changes have been said announce nothing' );
}

# --- proved by comparing for difference again ---------------------------------
#
# The guard as it was: anything that is not the recorded value is an upgrade.
# Ten alternating passes, ten announcements, which is what the bridge was
# doing while this was written.

{
    my $forgetful = File::Spec->catdir( $tmp, 'forgetful' );
    my $announced = 0;

    # The guard as it was: the last version seen, and nothing about what has
    # already been said. Reproduced by clearing the record of what was said
    # before every pass, which is exactly what not keeping it amounts to.
    for ( 1 .. 5 ) {
        for my $version ( '2.35', '2.34' ) {
            my $ledger = $tira->_enforcement_read($forgetful) || {};
            delete $ledger->{announced_changes};
            $tira->_enforcement_write( $forgetful, $ledger );

            no warnings 'redefine';
            local $Tira::VERSION = $version;
            my $pass = $tira->police_pass( project => $root, store => $forgetful,
                world => {} );
            $announced++ if $pass->{upgraded};
        }
    }

    cmp_ok( $announced, '>=', 9,
        'with no record of what was said, an upgrade is announced on almost every pass' );
}

# --- and a version nobody has mentioned is still announced --------------------

{
    my $said = pass_at('2.36');
    ok( $said, 'a genuine upgrade is announced after all that' );
    is( $said->{to}, '2.36', 'naming the new version' );
}

done_testing;

__END__

=head1 NAME

246-an-upgrade-announced-once.t - each change said once, not each difference

=head1 DESCRIPTION

The upgrade notice was written whenever the running version differed from the
one recorded. A difference has two directions, so two watchers at different
versions announced an upgrade to each other for ever - measured on this board
as two opposite notices nine seconds apart.

The board records which changes it has already announced. Each is news once, so
two watchers taking turns say it twice and then stop, and a rollback - which
C<t/175> requires - is still announced the first time.

=cut
