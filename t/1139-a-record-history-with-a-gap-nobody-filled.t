#!/usr/bin/env perl
# TKT-1082. evidence_add and gate_add mint their next id from
# `scalar(@list) + 1` - the exact scheme TKT-642 already replaced for
# required_item_add and checklist_add, for the identical reason: correct
# only while nothing ever shortens the list. Nothing removes an evidence or
# gate_passing_log entry today (not a live bug), but their ids are read
# back by evidence.annotate/gate.annotate - TKT-490 already refused an
# unknown GATE-NNN/EVD-NNN by name, implying these are treated as stable
# references - and gate_passing_log entries are what verify/pending-push
# proofs point to. A third call site shares the identical pattern:
# _log_proof_gate, the helper required_item_update's own auto-announce
# path uses to log a passed gate.
#
# conversation_add, and now required_item_add/checklist_add (TKT-642),
# already scan for the highest existing number rather than counting - this
# proves evidence_add, gate_add, and _log_proof_gate (reached here through
# required_item_update's auto-announce path, the same public entrypoint
# TKT-1082's own key_details name) should do the same. Same technique as
# t/1085 (TKT-642's sibling test): splice the record directly to simulate
# a hand-removal, write it back via _replace_record, then prove the next
# add does not collide.
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
my $root = File::Spec->catdir( $tmp, 'ids' );
my $tira = Tira->new( clock => sub { '2026-09-21T00:00:00Z' } );
$tira->project_new( name => 'Ids', dir => $root, members => ['claude'] );

# --- evidence_add: a removed entry does not collide with a surviving one ---

{
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Evidence' );
    for my $summary (qw(First Second Third)) {
        $tira->evidence_add( author => 'claude', project => $root, ref => $record->{ref}, summary => $summary );
    }
    my $shown = $tira->record_show( project => $root, ref => $record->{ref} );
    is_deeply( [ map { $_->{id} } @{ $shown->{evidence} } ], [qw(EVD-001 EVD-002 EVD-003)],
        'three evidence entries get three sequential ids' );

    my @kept = grep { $_->{id} ne 'EVD-002' } @{ $shown->{evidence} };
    $shown->{evidence} = \@kept;
    $tira->_replace_record( project => $root, ref => $record->{ref}, record => $shown );

    my $fourth = $tira->evidence_add( author => 'claude', project => $root, ref => $record->{ref}, summary => 'Fourth' );
    is( $fourth->{id}, 'EVD-004', 'the next evidence entry after a middle removal is EVD-004, not the collided EVD-002' );

    # The one case a max-scan structurally cannot close, pinned explicitly
    # the same way t/1085 pins it for required_items/checklist rather than
    # leaving a reader to assume it too is fixed.
    $shown = $tira->record_show( project => $root, ref => $record->{ref} );
    @kept = grep { $_->{id} ne 'EVD-004' } @{ $shown->{evidence} };
    $shown->{evidence} = \@kept;
    $tira->_replace_record( project => $root, ref => $record->{ref}, record => $shown );

    my $fifth = $tira->evidence_add( author => 'claude', project => $root, ref => $record->{ref}, summary => 'Fifth' );
    is( $fifth->{id}, 'EVD-004', 'removing the LAST evidence entry reissues its own id on the next add - the documented max-scan limit, not a bug' );
}

# --- gate_add: a removed entry does not collide with a surviving one ------

{
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Gates' );
    for my $details (qw(First Second Third)) {
        $tira->gate_add( author => 'claude', project => $root, ref => $record->{ref},
            gate => 'required-action', result => 'pass', details => $details );
    }
    my $shown = $tira->record_show( project => $root, ref => $record->{ref} );
    is_deeply( [ map { $_->{id} } @{ $shown->{gate_passing_log} } ], [qw(GATE-001 GATE-002 GATE-003)],
        'three gate entries get three sequential ids' );

    my @kept = grep { $_->{id} ne 'GATE-002' } @{ $shown->{gate_passing_log} };
    $shown->{gate_passing_log} = \@kept;
    $tira->_replace_record( project => $root, ref => $record->{ref}, record => $shown );

    my $fourth = $tira->gate_add( author => 'claude', project => $root, ref => $record->{ref},
        gate => 'required-action', result => 'pass', details => 'Fourth' );
    is( $fourth->{id}, 'GATE-004', 'the next gate entry after a middle removal is GATE-004, not the collided GATE-002' );

    # Codex review: the LAST-item limit was only pinned for evidence_add
    # above, not for gate_add directly, even though it is the identical
    # implementation. Pinned here too rather than left to assume.
    $shown = $tira->record_show( project => $root, ref => $record->{ref} );
    @kept = grep { $_->{id} ne 'GATE-004' } @{ $shown->{gate_passing_log} };
    $shown->{gate_passing_log} = \@kept;
    $tira->_replace_record( project => $root, ref => $record->{ref}, record => $shown );

    my $fifth = $tira->gate_add( author => 'claude', project => $root, ref => $record->{ref},
        gate => 'required-action', result => 'pass', details => 'Fifth' );
    is( $fifth->{id}, 'GATE-004', 'removing the LAST gate entry reissues its own id on the next add - the documented max-scan limit, not a bug' );
}

# --- required_item_update's auto-announce path shares the same fix --------
#
# _log_proof_gate is reached through the public entrypoint TKT-1082's own
# key_details name: marking a required item done with --command/--proof
# writes a gate_passing_log entry through this same length-based id scheme,
# a second, separate call site TKT-642 never touched.

{
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Auto-announce' );

    # _log_proof_gate only fires when a required item's RESULTING status is
    # 'done' (lib/Tira.pm ~5493) - three separate items, each marked done
    # once with its own command/proof, exercises it three times the same
    # way three real required-action gates on a real card would.
    for my $n ( 1 .. 3 ) {
        $tira->required_item_add( author => 'claude', project => $root, ref => $record->{ref},
            item => "Step $n", status => 'pending' );
        $tira->required_item_update( author => 'claude', project => $root, ref => $record->{ref},
            id => "REQ-00$n", status => 'done', command => ["step $n"], proof => ["proof $n"] );
    }
    my $shown = $tira->record_show( project => $root, ref => $record->{ref} );
    is_deeply( [ map { $_->{id} } @{ $shown->{gate_passing_log} } ], [qw(GATE-001 GATE-002 GATE-003)],
        'three auto-announced gate entries get three sequential ids' );

    my @kept = grep { $_->{id} ne 'GATE-002' } @{ $shown->{gate_passing_log} };
    $shown->{gate_passing_log} = \@kept;
    $tira->_replace_record( project => $root, ref => $record->{ref}, record => $shown );

    $tira->required_item_add( author => 'claude', project => $root, ref => $record->{ref},
        item => 'Step 4', status => 'pending' );
    $tira->required_item_update( author => 'claude', project => $root, ref => $record->{ref},
        id => 'REQ-004', status => 'done', command => ['step 4'], proof => ['proof 4'] );
    $shown = $tira->record_show( project => $root, ref => $record->{ref} );
    is( $shown->{gate_passing_log}[-1]{id}, 'GATE-004',
        'the auto-announce path after a middle removal is GATE-004, not the collided GATE-002' );

    # Codex review: same LAST-item limit, pinned for this third call site too.
    @kept = grep { $_->{id} ne 'GATE-004' } @{ $shown->{gate_passing_log} };
    $shown->{gate_passing_log} = \@kept;
    $tira->_replace_record( project => $root, ref => $record->{ref}, record => $shown );

    $tira->required_item_add( author => 'claude', project => $root, ref => $record->{ref},
        item => 'Step 5', status => 'pending' );
    $tira->required_item_update( author => 'claude', project => $root, ref => $record->{ref},
        id => 'REQ-005', status => 'done', command => ['step 5'], proof => ['proof 5'] );
    $shown = $tira->record_show( project => $root, ref => $record->{ref} );
    is( $shown->{gate_passing_log}[-1]{id}, 'GATE-004',
        'removing the LAST auto-announced gate entry reissues its own id on the next add too' );
}

# --- existing records with existing ids are unaffected ---------------------

{
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Unaffected by the fix' );
    my $first = $tira->evidence_add( author => 'claude', project => $root, ref => $record->{ref}, summary => 'Untouched' );
    is( $first->{id}, 'EVD-001', 'a fresh record still mints EVD-001 first, exactly as before' );
}

done_testing;

__END__

=head1 NAME

1139-a-record-history-with-a-gap-nobody-filled.t - a removed evidence/gate
id does not collide with a surviving one

=head1 DESCRIPTION

TKT-1082. C<evidence_add>, C<gate_add>, and C<_log_proof_gate>
(C<required_item_update>'s own auto-announce path) all derived their next
id from C<scalar(@list) + 1>, the exact scheme TKT-642 already replaced for
C<required_item_add>/C<checklist_add> and for the identical reason.

Simulates a hand-removal (there is no evidence/gate removal command today)
by splicing the record directly and writing it back via C<_replace_record>,
the same technique C<t/1085> uses for TKT-642, then proves the next add
does not collide with a surviving id across all three call sites.

=cut
