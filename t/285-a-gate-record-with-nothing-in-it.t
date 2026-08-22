#!/usr/bin/env perl
# gate.add's own usage line lists --gate and --details as required - no
# brackets, unlike --author - and the command accepted a call missing both,
# exiting 0 and writing a record with gate:null and details:null.
#
# Found while recording a release's own evidence: "d2 tira.gate.add --ref
# TKT-386 --result pass --note ..." (missing --gate and --details; --note is
# not even a flag this command takes) exited 0 and created a gate entry
# carrying nulls for the two fields the whole point of a gate record is to
# name. evidence.add gets this right for its own required field: the same
# investigation called it without --summary and it refused correctly,
# "Evidence summary is required", nothing persisted. gate.add should match
# that behaviour for its own required fields rather than persisting a record
# that answers "a gate exists" while carrying none of the information that
# answer depends on.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-19T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Gated', dir => $root, members => ['claude'],
    columns => ['backlog, verify, done'],
    sow_prefix => 'GDS', epic_prefix => 'GDE', ticket_prefix => 'GDT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Proved how?' );

# --- missing --gate is refused, not silently null'd -------------------------

{
    my $result = eval {
        $tira->gate_add( author => 'claude', project => $root, ref => $card->{ref},
            result => 'pass', details => 'the suite passed' );
    };
    ok( !$result, 'calling gate.add without --gate is refused' );
    like( $@ // '', qr/gate/i, 'and says what is missing' );

    my $stored = $tira->gate_list( project => $root, ref => $card->{ref} );
    is_deeply( $stored, [], 'and nothing was persisted' );
}

# --- missing --details is refused the same way ------------------------------

{
    my $result = eval {
        $tira->gate_add( author => 'claude', project => $root, ref => $card->{ref},
            gate => 'coverage', result => 'pass' );
    };
    ok( !$result, 'calling gate.add without --details is refused' );
    like( $@ // '', qr/details/i, 'and names the missing field' );

    my $stored = $tira->gate_list( project => $root, ref => $card->{ref} );
    is_deeply( $stored, [], 'and nothing was persisted' );
}

# --- with everything present, it still works exactly as before -------------

{
    my $entry = $tira->gate_add( author => 'claude', project => $root, ref => $card->{ref},
        gate => 'coverage', result => 'pass', details => 'the suite passed' );
    ok( $entry->{id}, 'with everything required present, the call succeeds' );
    is( $entry->{gate}, 'coverage', 'carrying the gate name' );
    is( $entry->{details}, 'the suite passed', 'and the details' );

    my $stored = $tira->gate_list( project => $root, ref => $card->{ref} );
    is( scalar @{$stored}, 1, 'and this time something was persisted' );
}

# --- proved by breaking it: without the checks, the original defect returns --

{
    no warnings 'redefine';
    local *Tira::gate_add = sub {
        my ( $self, %args ) = @_;
        my $root = $self->discover_project(%args);
        return $self->_with_project_lock( $root, sub {
            die "Invalid gate result\n" if ( $args{result} // '' ) !~ /\A(?:pass|fail|blocked)\z/;
            my $record = $self->record_show(%args);
            my $entry = {
                id => sprintf( 'GATE-%03d', @{ $record->{gate_passing_log} } + 1 ),
                gate => $args{gate}, result => $args{result}, details => $args{details},
                author => $args{author}, annotations => [], created_at => $self->{clock}->(),
            };
            push @{ $record->{gate_passing_log} }, $entry;
            $self->_replace_record( %args, record => $record );
            return $entry;
        } );
    };

    my $entry = $tira->gate_add( author => 'claude', project => $root, ref => $card->{ref}, result => 'pass' );
    ok( $entry->{id}, 'without the checks, the same call succeeds again' );
    ok( !defined $entry->{gate}, 'and gate is null - the exact defect this card reports' );
}

done_testing;

__END__

=head1 NAME

285-a-gate-record-with-nothing-in-it.t - TKT-408

=head1 DESCRIPTION

C<gate.add>'s usage line names C<--gate> and C<--details> as required, and
the command accepted a call missing both, persisting a record with
C<gate:null> and C<details:null>. C<evidence.add> already refuses correctly
for its own missing C<--summary> - this brings C<gate.add> in line with that
existing behaviour rather than leaving a gate record that satisfies "a gate
was recorded" while carrying none of the information that claim depends on.

=cut
