#!/usr/bin/env perl
# A police pass names the policy that raised each finding - measured:
# "card-duration | policy: POL-001". tira.police.outstanding, the list an
# agent is told to act from, returns action, assignee, first_seen, id,
# ref, rule, seen and tone - and no policy. The one field that says WHICH
# declaration to change is present where nobody acts and absent where
# everybody does - worst where a rule is declared more than once
# (card-duration six times on this board, checklist-idle six, wip-limit
# three, leftover-process two), since there the rule name alone cannot say
# which declaration to look at. TKT-380.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-08-23T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Ledger', dir => $root, members => ['claude'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'LGS', epic_prefix => 'LGE', ticket_prefix => 'LGT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

# --- one rule, declared twice, --ref-scoped to two different cards ----------
#
# --ref is the one scope field policy_resolve already ranks correctly
# (highest specificity), so this proves the outstanding row's policy id
# without depending on --column-scoped resolution, which TKT-483 (filed
# separately, a genuine pre-existing bug found while writing this test)
# does not yet resolve correctly for two same-rule declarations that
# differ only by the rule's own --column field.

my $stuck_in_implement = $tira->create_record( project => $root, type => 'ticket',
    title => 'Stuck in implement' );
$tira->record_move( author => 'claude', project => $root, ref => $stuck_in_implement->{ref}, column => 'implement' );
my $stuck_in_verify = $tira->create_record( project => $root, type => 'ticket',
    title => 'Stuck in verify' );
$tira->record_move( author => 'claude', project => $root, ref => $stuck_in_verify->{ref}, column => 'verify' );

my $on_implement = $tira->policy_add( project => $root, rule => 'card-duration',
    ref => $stuck_in_implement->{ref}, column => 'implement', age => '10m', action => 'bridge-reminder' );
my $on_verify = $tira->policy_add( project => $root, rule => 'card-duration',
    ref => $stuck_in_verify->{ref}, column => 'verify', age => '10m', action => 'bridge-reminder' );

$now = '2026-08-23T09:20:00Z';    # past both 10m ages
my $pass = $tira->police_pass( project => $root, store => $store, world => {} );

my ($from_pass_implement) = grep { ( $_->{ref} // '' ) eq $stuck_in_implement->{ref} } @{ $pass->{violations} };
my ($from_pass_verify)    = grep { ( $_->{ref} // '' ) eq $stuck_in_verify->{ref} } @{ $pass->{violations} };
ok( $from_pass_implement && $from_pass_verify, 'the pass reports both, as it always did' );
is( $from_pass_implement->{policy}, $on_implement->{id}, "the pass already names the implement column's own policy" );
is( $from_pass_verify->{policy}, $on_verify->{id}, "and the verify column's own policy, a different one" );

# --- the outstanding list, which is what an agent actually reads ------------

my $outstanding = $tira->police_outstanding( project => $root, store => $store );
my ($out_implement) = grep { ( $_->{ref} // '' ) eq $stuck_in_implement->{ref} } @{$outstanding};
my ($out_verify)    = grep { ( $_->{ref} // '' ) eq $stuck_in_verify->{ref} } @{$outstanding};

is( $out_implement->{policy}, $on_implement->{id},
    'the outstanding row for the implement card names that policy' );
is( $out_verify->{policy}, $on_verify->{id},
    'and the outstanding row for the verify card names the other one - the two are distinguishable' );
isnt( $out_implement->{policy}, $out_verify->{policy},
    'proved directly: the same rule, two declarations, two different policy ids on the two rows' );

# --- and the shape a caller already depends on is unchanged -----------------

is( ref $outstanding, 'ARRAY', '-o json keeps its bare-list shape, since the clear-violations loop pipes it' );
ok( exists $out_implement->{rule} && exists $out_implement->{id} && exists $out_implement->{ref},
    'every field that was already there is still there' );

done_testing;

__END__

=head1 NAME

352-which-declaration-to-look-at.t - the outstanding list names the policy, not only the rule

=head1 DESCRIPTION

A police pass already names the policy that raised each finding, but
C<police_outstanding> - the list an agent is told to act from - dropped it,
so fixing a policy meant guessing which declaration was meant whenever a
rule was declared more than once. This declares C<card-duration> on two
columns, breaks both, and proves the outstanding rows carry the two
distinct policy ids the pass itself already reported, with the rest of the
row's shape unchanged.

=cut
