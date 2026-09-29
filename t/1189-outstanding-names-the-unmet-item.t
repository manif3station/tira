#!/usr/bin/env perl
# TKT-1189. police_outstanding's own returned entries carry only
# {id, rule, policy, ref, assignee, action, seen, tone, first_seen, last_seen}
# - the detail/message the report() call already built (which, for
# required-unsatisfied, names the specific unmet REQ id and item text) is
# computed on every police pass and then thrown away before it reaches the
# ledger: _violation_record_locked's \$entry->{about} is built from only
# qw(rule policy ref action assignee project), so a later call to
# police_outstanding (which reads only the ledger) can never see it.
#
# Diagnosing 161 outstanding required-unsatisfied violations on the real
# board required a ticket.show round-trip per ref just to find out which
# required item was pending - the answer was already in \$violation at
# report time and simply never carried through storage.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $store = File::Spec->catdir( $tmp, 'store' );
my $root  = File::Spec->catdir( $tmp, 'proj' );

my $tira = Tira->new( clock => sub {'2026-09-28T09:00:00Z'} );
$tira->project_new(
    name => 'Outstanding Detail', dir => $root, members => ['claude'],
    columns => ['backlog, tests-red, implement, done'],
);
$tira->policy_add(
    project => $root, rule => 'required-unsatisfied', action => 'bridge-reminder',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Owes its own column' );
$tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'tests-red' );
$tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
    column => 'tests-red', item => 'Write the failing test first', status => 'pending' );

my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
$tira->bridge_write( store => $store, project => $root,
    violations => $pass->{violations}, settled => $pass->{settled} );

# --- the per-pass violation already knows the answer ------------------------

my ($violation) = grep { $_->{rule} eq 'required-unsatisfied' } @{ $pass->{violations} };
ok( $violation, 'the pass reports the unmet item' );
like( $violation->{detail}, qr/Write the failing test first/,
    'and its own detail already names the item text' );

# --- but the ledger-backed outstanding view throws it away ------------------
#
# This is the actual gap: police_outstanding reads the ledger, not the
# per-pass violation list, and the ledger never kept detail/message.

my ($open) = grep { $_->{rule} eq 'required-unsatisfied' } @{ $tira->police_outstanding( store => $store ) };
ok( $open, 'the same finding is outstanding' );
like( $open->{detail} // '', qr/Write the failing test first/,
    'and the outstanding entry itself should still name the item, without a follow-up ticket.show' );

done_testing;

__END__

=head1 NAME

1189-outstanding-names-the-unmet-item.t - a diagnosis thrown away on the way to disk

=head1 DESCRIPTION

required-unsatisfied's own report() call already builds "REQ-XXX: item text"
into its violation's detail. _violation_record_locked's ledger write keeps
only rule/policy/ref/action/assignee/project on \$entry->{about}, so
police_outstanding - which reads only the ledger - can never answer which
item is unmet without a separate ticket.show per ref.

=cut
