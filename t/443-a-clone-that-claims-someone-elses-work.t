#!/usr/bin/env perl
# TKT-609. record_clone copies gate_passing_log and evidence to the new
# card - a brand-new card, with no required items and nothing done on it,
# arrives claiming a passed gate and a piece of evidence naming a command
# and output from work that happened on the ORIGINAL.
#
# Reproduced in a container before this test was written: a card gets a
# real gate.add and evidence.add, is cloned, and the clone's gate_passing_log
# and evidence are the original's, verbatim.
#
# THIS CARD'S OWN HISTORY IS THE REASON FOR THE SECOND CONTROL BELOW. Its
# first version claimed evidence was correctly dropped and only
# gate_passing_log leaked - measured wrong. A later, separate card (TKT-705)
# measured it correctly. Both fields are checked here so neither half of
# the original mistake can recur silently.
#
# required_items and checklist are already correctly dropped (t/05's own
# clone test never asserts them, and a direct read confirms they are
# absent) - not re-litigated here. attachments are DELIBERATELY preserved
# (t/05-collaboration.t:83, "clone preserves record attachment refs") and
# that control is repeated here so this fix cannot widen into dropping
# something the project has already decided to keep.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-08-30T03:00:00Z'} );

$tira->project_new(
    name => 'Cloned', dir => $root, members => ['claude'],
    columns    => [ 'backlog', 'implement', 'done' ],
    sow_prefix => 'CLS', epic_prefix => 'CLE', ticket_prefix => 'CLT',
);

my $original = $tira->create_record( project => $root, type => 'ticket', title => 'Did the real work' );
$tira->gate_add(
    project => $root, ref => $original->{ref}, gate => 'implement',
    result => 'pass', details => 'the real command -> the real output', author => 'claude',
);
$tira->evidence_add(
    project => $root, ref => $original->{ref}, summary => 'suite green, 8894 tests', author => 'claude',
);
$tira->attachment_add_content(
    project => $root, ref => $original->{ref}, filename => 'log.txt', content => 'a log',
);

my $clone = $tira->record_clone( project => $root, ref => $original->{ref}, title => 'Never did anything', author => 'claude' );

# --- THE CARD ---------------------------------------------------------------

# create_record always initializes both to a real [], never undef - checked
# first so a regression that dropped the field entirely (schema-absent)
# cannot pass this assertion by accident the way a missing key would.
is( ref $clone->{gate_passing_log}, 'ARRAY', 'the clone has a real gate_passing_log array, not a missing field' );
is( scalar @{ $clone->{gate_passing_log} }, 0,
    'a clone carries no gate_passing_log entries from the original' );

is( ref $clone->{evidence}, 'ARRAY', 'and a real evidence array too, not a missing field' );
is( scalar @{ $clone->{evidence} }, 0,
    'and no evidence entries either - the half this card originally got wrong' );

# --- THE ORIGINAL IS UNTOUCHED ------------------------------------------------

my $reread = $tira->record_show( project => $root, ref => $original->{ref} );
is( scalar @{ $reread->{gate_passing_log} // [] }, 1, 'the original keeps its own gate log' );
is( scalar @{ $reread->{evidence} // [] }, 1, 'and its own evidence, both unaffected by the clone' );

# --- THE CONTROL: attachments are deliberately preserved, and must stay so --

is( scalar @{ $clone->{attachments} // [] }, 1,
    'attachments are still preserved on the clone - t/05-collaboration.t already '
      . 'established this is intentional, and this fix must not widen into '
      . 'dropping it too' );

# --- A clone that later earns its own gate records its own entry ------------

$tira->gate_add(
    project => $root, ref => $clone->{ref}, gate => 'implement',
    result => 'pass', details => 'the clone did its own work this time', author => 'claude',
);
my $clone_after = $tira->record_show( project => $root, ref => $clone->{ref} );
is( scalar @{ $clone_after->{gate_passing_log} }, 1, 'a clone can still pass a gate of its own' );
like( $clone_after->{gate_passing_log}[0]{details}, qr/the clone did its own work/,
    'and the entry is genuinely its own, not the one it started with' );

done_testing();

__END__

=head1 NAME

t/443-a-clone-that-claims-someone-elses-work.t - a cloned card must not
inherit proof of work it never did

=head1 DESCRIPTION

C<record_clone> copied C<gate_passing_log> and C<evidence> onto the new
card, so a brand-new card with no required items and nothing done on it
arrived claiming a passed gate and evidence from the original. TKT-609's
own first version measured only the gate log half; a later card, TKT-705,
found evidence leaked too - both are asserted here so the mistake cannot
recur in either direction.

=head2 What is deliberately unchanged

C<attachments> are preserved on a clone by design
(t/05-collaboration.t:83) and that control is repeated here, because the
fix for this card must add exactly two fields to C<record_clone>'s delete
list, not widen it into dropping something the project already decided to
keep.

=cut
