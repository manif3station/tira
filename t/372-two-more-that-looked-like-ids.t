#!/usr/bin/env perl
# TKT-490, found following TKT-488's own key_details, which explicitly
# flagged these two sites as out of scope for that ticket and noted for a
# future one: _indexed_log_read (gate.list --id, evidence.list --id) and
# _annotate_log (gate.annotate, evidence.annotate) shared the identical bug
# TKT-280 fixed for checklist_update and TKT-488 fixed for
# required_item_update - an unknown id refused with only "not found", naming
# neither the GATE-NNN/EVD-NNN shape nor the ids the card actually has.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Logged', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'LGS', epic_prefix => 'LGE', ticket_prefix => 'LGT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card with real gate and evidence entries', priority => 3 );
$tira->gate_add( project => $root, type => 'ticket', ref => $card->{ref},
    author => 'claude', gate => 'G1', result => 'pass', details => 'first' );
$tira->gate_add( project => $root, type => 'ticket', ref => $card->{ref},
    author => 'claude', gate => 'G2', result => 'pass', details => 'second' );
$tira->evidence_add( project => $root, type => 'ticket', ref => $card->{ref},
    author => 'claude', summary => 'measured' );

my $empty = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card with no gate or evidence yet', priority => 3 );

# --- gate.list --id, a real card ---------------------------------------------

{
    my $error = eval { $tira->gate_list( project => $root, type => 'ticket', ref => $card->{ref}, id => '1' ); '' } // $@;
    like( $error, qr/Gate entry '1' not found/, 'gate.list --id still refuses the ordinal' );
    like( $error, qr/GATE-001/, 'and lists the card\'s real gate ids' );
    like( $error, qr/GATE-002/, 'both of them' );
}

# --- gate.list --id, an empty card -------------------------------------------

{
    my $error = eval { $tira->gate_list( project => $root, type => 'ticket', ref => $empty->{ref}, id => 'GATE-001' ); '' } // $@;
    like( $error, qr/GATE-001, \.\.\./, 'and names the shape when there is nothing to list' );
}

# --- gate.annotate ------------------------------------------------------------

{
    my $error = eval { $tira->gate_annotate( project => $root, type => 'ticket', ref => $card->{ref},
        author => 'claude', id => '1', note => 'n' ); '' } // $@;
    like( $error, qr/GATE-001/, 'gate.annotate names the real ids too' );
}

# --- evidence.list --id --------------------------------------------------------

{
    my $error = eval { $tira->evidence_list( project => $root, type => 'ticket', ref => $card->{ref}, id => '1' ); '' } // $@;
    like( $error, qr/Evidence entry '1' not found/, 'evidence.list --id still refuses the ordinal' );
    like( $error, qr/EVD-001/, 'and lists the card\'s real evidence id' );
}

# --- evidence.annotate ---------------------------------------------------------

{
    my $error = eval { $tira->evidence_annotate( project => $root, type => 'ticket', ref => $empty->{ref},
        author => 'claude', id => '1', note => 'n' ); '' } // $@;
    like( $error, qr/EVD-001, \.\.\./, 'evidence.annotate names the shape on an empty card' );
}

done_testing;

__END__

=head1 NAME

372-two-more-that-looked-like-ids.t - gate/evidence lookups name the id shape too

=head1 DESCRIPTION

Same bug as TKT-280 and TKT-488, two more call sites: C<_indexed_log_read>
(behind C<gate.list --id> and C<evidence.list --id>) and C<_annotate_log>
(behind C<gate.annotate> and C<evidence.annotate>) refused an unknown id
with only "not found", naming neither the C<GATE-NNN>/C<EVD-NNN> shape nor
the ids the card actually has. Both are shared/generic functions
parameterized by C<%LOG_SPEC>, so one fix in each covers gate and evidence
together.

=cut
