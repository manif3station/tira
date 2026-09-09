#!/usr/bin/env perl
# card-duration already accepts --type (the generic policy scope every rule
# shares - _policy_applies_to and _policy_specificity already read it), so
# two policies for the same column and different record types already
# coexist correctly: each judges only its own kind, and an unscoped policy
# is unaffected. What is missing is the finding itself - the detail text
# says only "in $column since $timestamp", naming neither the record type
# a type-scoped policy watches nor the threshold that fired, so two
# type-scoped card-duration policies on the same column produce identical-
# looking findings a reader cannot tell apart.
#
# Measured 2026-08-29/2026-09-09 in the perl-test container: an epic-scoped
# policy at 58h and a sow-scoped policy at 130h on the same column already
# judge only their own kind (an epic breaching at 60h, a sow at 60h not
# breaching its 130h threshold) - but the epic's finding detail reads
# "in in-progress since 2026-09-01T00:00:00Z" with no mention of "epic" or
# "58h" anywhere in the message a reader sees.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-09-01T00:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'A threshold that fits only one shape', dir => $root, members => ['claude'],
    columns => ['backlog, in-progress, done'],
    sow_prefix => 'TFS', epic_prefix => 'TFE', ticket_prefix => 'TFT',
);

$tira->policy_add(
    project => $root, rule => 'card-duration', column => 'in-progress',
    type => 'epic', age => '58h', action => 'log-only',
);
$tira->policy_add(
    project => $root, rule => 'card-duration', column => 'in-progress',
    type => 'sow', age => '130h', action => 'log-only',
);

my $epic = $tira->create_record( project => $root, type => 'epic', title => 'A long epic' );
my $sow  = $tira->create_record( project => $root, type => 'sow',  title => 'A longer sow' );
$tira->record_move( project => $root, ref => $epic->{ref}, column => 'in-progress', author => 'claude' );
$tira->record_move( project => $root, ref => $sow->{ref},  column => 'in-progress', author => 'claude' );

# --- AC1/AC2, already true today: type-scoped policies already coexist ------

$tira->{clock} = sub {'2026-09-03T12:00:00Z'};    # 60 hours later
my $findings = $tira->policy_evaluate( project => $root );

is( scalar @{$findings}, 1, 'only the epic (over its 58h threshold) is reported, not the sow (under its 130h)' );
is( $findings->[0]{ref}, $epic->{ref}, 'the one finding is against the epic' );

# --- AC3, the actual gap: the finding names the type-scoped threshold -------

like( $findings->[0]{message} // $findings->[0]{detail}, qr/\bepic\b/i,
    'the finding names which record type the fired threshold was scoped to' );
like( $findings->[0]{message} // $findings->[0]{detail}, qr/58h?\b/,
    'the finding names the threshold value that fired' );

# --- AC1 control: an unscoped policy is unaffected --------------------------

my $tmp2   = tempdir( CLEANUP => 1 );
my $root2  = File::Spec->catdir( $tmp2, 'proj' );
my $tira2  = Tira->new( clock => sub {$now} );
$tira2->project_new(
    name => 'Unscoped control', dir => $root2, members => ['claude'],
    columns => ['backlog, in-progress, done'],
    sow_prefix => 'UCS', epic_prefix => 'UCE', ticket_prefix => 'UCT',
);
$tira2->policy_add(
    project => $root2, rule => 'card-duration', column => 'in-progress',
    age => '58h', action => 'log-only',
);
my $ticket = $tira2->create_record( project => $root2, type => 'ticket', title => 'Any ticket' );
$tira2->record_move( project => $root2, ref => $ticket->{ref}, column => 'in-progress', author => 'claude' );
$tira2->{clock} = sub {'2026-09-03T12:00:00Z'};
my $unscoped_findings = $tira2->policy_evaluate( project => $root2 );
is( scalar @$unscoped_findings, 1, 'an unscoped card-duration policy still fires exactly as before' );
unlike( $unscoped_findings->[0]{message} // $unscoped_findings->[0]{detail}, qr/\bticket\b/i,
    'and does not claim a type-scoped threshold it never declared' );

done_testing();

__END__

=head1 NAME

t/756-a-threshold-that-fits-only-one-shape.t - card-duration's finding
names which type's threshold fired

=head1 DESCRIPTION

TKT-756. The ticket's own claim that card-duration "cannot be scoped per
record type" turned out to be stale: C<--type> is already a generic policy
scope field (C<@POLICY_SCOPE>, read by C<_policy_applies_to> and
C<_policy_specificity>) that every rule, card-duration included, already
honors - two policies for the same column and different types already
coexist correctly, and an unscoped policy is already unaffected. The actual
gap was narrower: the finding's own detail text named the column and the
timestamp but never the record type a type-scoped policy watches or the
threshold that fired, so two type-scoped card-duration findings on the same
column read identically. The card-duration branch of C<policy_evaluate> now
adds that when C<$policy-E<gt>{type}> is set.

=cut
