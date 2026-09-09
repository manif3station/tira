#!/usr/bin/env perl
# gate_add's own "Gate details are required" check tests only for the exact
# empty string, so a whitespace-only --details satisfies "required" -
# required_action_update already drew the line at whitespace-not-content
# for the same purpose (TKT-585), and evidence_add turns out to already
# use that same stronger check too (verified live, correcting this
# ticket's own claim that evidence_add shared the gap).
#
# Measured 2026-08-30 in a container: gate.add --details "   " succeeded,
# storing a gate result with nothing readable explaining it.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $now  = '2026-09-09T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->create_project( name => 'A details field with nothing in it', dir => $root );
$tira->person_add( project => $root, id => 'claude', name => 'Claude' );
$tira->create_record( project => $root, type => 'ticket', title => 'Contended' );

# --- gate_add: whitespace-only --details is refused like an empty one ------

eval { $tira->gate_add( project => $root, ref => 'TKT-001', gate => 'implement', result => 'pass', details => '', author => 'claude' ) };
my $empty_error = $@;
like( $empty_error, qr/Gate details are required/, 'an empty --details is refused (control)' );

eval { $tira->gate_add( project => $root, ref => 'TKT-001', gate => 'implement', result => 'pass', details => '   ', author => 'claude' ) };
is( $@, $empty_error, 'a whitespace-only --details is refused with the exact same message as empty' );

my $card = $tira->record_show( project => $root, ref => 'TKT-001' );
is( scalar @{ $card->{gate_passing_log} }, 0, 'neither refused call recorded a gate entry' );

# --- gate_add: real content with incidental padding still succeeds ---------

my $entry = $tira->gate_add(
    project => $root, ref => 'TKT-001', gate => 'implement', result => 'pass',
    details => '  a real reason  ', author => 'claude',
);
is( $entry->{details}, '  a real reason  ', 'padded-but-real details are accepted and stored unchanged' );

# --- evidence_add: already fixed - control confirming the ticket's own ------
# --- "same eq '' shape" claim about this command is stale -------------------

eval { $tira->evidence_add( project => $root, ref => 'TKT-001', summary => '   ', author => 'claude' ) };
like( $@, qr/Evidence summary is required/, 'evidence_add already refuses a whitespace-only --summary (this ticket\'s own claim about evidence_add was stale)' );

done_testing();

__END__

=head1 NAME

t/768-a-details-field-with-nothing-in-it.t - gate_add refuses a
whitespace-only --details the same way it refuses an empty one

=head1 DESCRIPTION

TKT-768. C<gate_add>'s own "Gate details are required" check tested only
for exact emptiness (C<eq ''>), so C<--details '   '> satisfied "required"
and stored a gate result with nothing readable explaining it -
C<required_action_update> already established the stronger
C<!~ /\S/> test for the identical purpose (TKT-585). C<evidence_add>,
which the ticket's own key_details claimed shared the identical gap,
already uses that stronger check - confirmed live rather than assumed,
correcting the ticket's own stale claim. Only C<gate_add> needed the fix.

=cut
