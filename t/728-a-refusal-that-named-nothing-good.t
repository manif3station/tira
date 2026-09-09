#!/usr/bin/env perl
# Tira refuses an unknown value in two styles, and the worse one is commoner.
#
# TKT-521 improvement hunt, 2026-08-29. Four refusals in lib/Tira.pm (the
# policy-rule ones) name the bad value and then list the permitted ones.
# At least eight others name the bad value and stop. This file covers the
# two hit while working the board that night: an unknown link type, and a
# missing checklist status.
#
# NARROWED FROM THE CARD'S FULL SCOPE, checked rather than assumed:
#   - checklist_add/checklist_update ALREADY name the permitted statuses
#     for an UNKNOWN status ("Unknown checklist status '...' - the values
#     that work are pending, done, and To Do") - only the MISSING-status
#     refusal ("Checklist status is required") says nothing.
#   - the link-type vocabulary IS already reachable from the CLI, via
#     `tira.project.link-types.list` (documented in SKILLS.md) - the card's
#     own claim that no such command exists is stale. What is missing is
#     the refusal naming them at the moment of failure, not a new command.
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
my $tira = Tira->new( clock => sub {'2026-09-09T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name          => 'A refusal that named nothing good',
    dir           => $root,
    members       => ['claude'],
    columns       => ['backlog, done'],
    sow_prefix    => 'RNS',
    epic_prefix   => 'RNE',
    ticket_prefix => 'RNT',
);

my $a = $tira->create_record( project => $root, type => 'ticket', title => 'One card' );
my $b = $tira->create_record( project => $root, type => 'ticket', title => 'Another card' );

# --- link.add with an unknown type ------------------------------------------

eval { $tira->link_add( project => $root, author => 'claude', from => $a->{ref}, to => $b->{ref}, type => 'nonsense' ) };
like( $@, qr/Unknown link type 'nonsense'/, 'the bad value is still named' );
like( $@, qr/relates-to/i,
    'and at least one real link type is named too, the way the policy-rule refusals already do' );

# --- checklist.add with no --status -----------------------------------------

eval { $tira->checklist_add( project => $root, author => 'claude', ref => $a->{ref}, item => 'Do the thing' ) };
like( $@, qr/status/i, 'the missing field is still named' );
like( $@, qr/pending/i,
    'and the permitted statuses are named too - the unknown-status refusal already does this, '
      . 'the missing-status one does not' );

# --- checklist.update given only --id, with --status set to the empty string -

my $entry = $tira->checklist_add(
    project => $root, author => 'claude', ref => $a->{ref}, item => 'Do the thing', status => 'pending' );
eval { $tira->checklist_update( project => $root, author => 'claude', ref => $a->{ref}, id => $entry->{id}, status => '' ) };
like( $@, qr/status/i, 'checklist_update names the missing field too' );
like( $@, qr/pending/i, 'and the permitted statuses too - the same fix, the sibling verb' );

# --- the four policy-rule refusals are unchanged ----------------------------

eval { $tira->policy_add( project => $root, rule => 'nonsense', enter => 'backlog', action => 'log-only' ) };
like( $@, qr/Unknown policy rule 'nonsense'\. Rules: /, 'the existing good refusal reads exactly as it does today' );

done_testing();

__END__

=head1 NAME

t/728-a-refusal-that-named-nothing-good.t - a refusal for an unknown or
missing value names the permitted values, wherever they are enumerable

=head1 DESCRIPTION

TKT-728. C<link_add>'s C<_reciprocal_type> and C<checklist_add>/
C<checklist_update>'s missing-status refusal both named what was wrong and
nothing about what would be right - the worse of the two refusal styles this
codebase already has a better one for (the policy-rule refusals, built on
C<policy_rules()>). Both are extended to join the permitted values into the
message, the same way the good style already does.

Scope was narrowed against the card's own claims after checking them: the
unknown-status checklist refusal already named its values, and a
C<tira.project.link-types.list> command already exists - only the missing-
status refusal and the unknown-link-type refusal were genuinely bare.

=cut
