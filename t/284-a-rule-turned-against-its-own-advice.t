#!/usr/bin/env perl
# leftover-process reported the one process bridge-unread tells an agent to
# keep running.
#
# Measured on this board. bridge-unread's own message says outright: "tail
# it with d2 tira.policy.bridge and keep it running while you work." A
# leftover-process policy was declared with pattern 'projects-skills' - broad
# enough to match any long-running process whose command line mentions this
# project's own path, which the bridge tail's does. It matched PID 1899 at
# 4h04m, correctly measured as old and still running, and entirely
# unactionable: the one thing to do with it is exactly what it was doing.
#
# The rule cannot tell a broad pattern from a wrong one - a string match is a
# string match - so this is the one process it is told about structurally
# rather than guessed at: the bridge tail is exempt from being reported,
# however broad the declared pattern is, because Tira's own advice put it
# there.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $tira  = Tira->new( clock => sub {'2026-08-18T12:00:00Z'} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Bridged', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'BDS', epic_prefix => 'BDE', ticket_prefix => 'BDT',
);

# The reported shape, reproduced: a pattern that means "any of my project's
# own long processes" and, because the bridge tail's own command line
# carries that same project path, matches it too.
$tira->policy_add( project => $root, rule => 'leftover-process',
    pattern => 'projects-skills', age => '2h', action => 'bridge-reminder' );

sub findings {
    my (%world) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store, world => \%world );
    return [ grep { $_->{rule} eq 'leftover-process' } @{ $pass->{violations} } ];
}

# --- the bridge tail, matching the pattern by coincidence -------------------

{
    my $found = findings(
        processes => [
            {   command    => "bash -c 'cd ~/projects-skills/tira && d2 tira.policy.bridge'",
                started_at => '2026-08-18T07:56:00Z',    # 4h04m before $now
            },
        ],
    );
    is( scalar @{$found}, 0,
        'the bridge tail is not reported, however broad the pattern that happens to match it' );
}

# --- while a genuinely different, old, matching process still is -----------
#
# The exemption has to be narrow. If it silenced the pattern generally rather
# than this one process specifically, the rule would stop being able to do
# the one thing it exists for.

{
    my $found = findings(
        processes => [
            {   command    => 'bash -c until sleep 5; do :; done # ~/projects-skills/tira leftover',
                started_at => '2026-08-18T07:56:00Z',
            },
        ],
    );
    is( scalar @{$found}, 1,
        'a genuinely different old process matching the same pattern is still reported' );
    like( $found->[0]{detail}, qr/still running/, 'and says what' );
}

# --- both together: one silent, one not --------------------------------------

{
    my $found = findings(
        processes => [
            {   command    => "bash -c 'd2 tira.policy.bridge' # projects-skills",
                started_at => '2026-08-18T07:56:00Z',
            },
            {   command    => 'bash -c until true; do sleep 1; done # projects-skills stray',
                started_at => '2026-08-18T07:56:00Z',
            },
        ],
    );
    is( scalar @{$found}, 1, 'exactly the one that is not the bridge tail is reported' );
    unlike( $found->[0]{detail}, qr/policy\.bridge/,
        'and it is not the bridge tail that was named' );
}

# --- a recent bridge tail is still not litter, for the ordinary reason -----
#
# Not reported because it is the bridge tail, and separately not reported
# because it has not been running long enough either - both hold at once and
# neither depends on the other.

{
    my $found = findings(
        processes => [
            {   command    => "bash -c 'cd ~/projects-skills/tira && d2 tira.policy.bridge'",
                started_at => '2026-08-18T11:55:00Z',
            },
        ],
    );
    is( scalar @{$found}, 0, 'a five-minute-old bridge tail is quiet, same as any recent process' );
}

# --- proved by breaking it: without the exemption, the defect comes back ---
#
# The exemption is its own named predicate, exactly so this is possible: turn
# it off and watch the original report return.

{
    no warnings 'redefine';
    local *Tira::_is_bridge_tail = sub { return 0 };

    my $found = findings(
        processes => [
            {   command    => "bash -c 'cd ~/projects-skills/tira && d2 tira.policy.bridge'",
                started_at => '2026-08-18T07:56:00Z',
            },
        ],
    );
    is( scalar @{$found}, 1,
        'without the exemption, the bridge tail is reported again - the exact defect measured on this board' );
    like( $found->[0]{detail}, qr/policy\.bridge/, 'naming it' );
}

done_testing;

__END__

=head1 NAME

284-a-rule-turned-against-its-own-advice.t - TKT-379

=head1 DESCRIPTION

C<bridge-unread>'s own message tells an agent to keep C<d2 tira.policy.bridge>
running. C<leftover-process> matches purely by substring, so a pattern meant
to catch a stray process from this project - sharing nothing more specific
than the project's own path - matched the bridge tail too, and reported it as
litter. C<leftover-process> now exempts the bridge tail structurally,
regardless of how broad the declared pattern is, while a genuinely different
process matching the same pattern is still reported exactly as before.

=cut
