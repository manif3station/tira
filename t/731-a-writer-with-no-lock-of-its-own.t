#!/usr/bin/env perl
# evidence.annotate and gate.annotate read-modify-write a whole card with
# no project lock, while every sibling write on this same path takes one.
#
# TKT-520 hourly bug hunt, 2026-08-29. _annotate_log reads the whole card,
# pushes an annotation into one of its log entries, and writes the whole
# card back - reached from evidence_annotate and gate_annotate, neither of
# which wraps it in _with_project_lock. t/53 already proves this exact
# technique (comment_add, checklist_add, gate_add, evidence_add and their
# siblings all hold the lock across their own read-modify-write); it never
# added the two annotate verbs, which is the gap this file closes.
#
# Because the write replaces the WHOLE record, this is not a narrow miss:
# an annotate racing any other card write on the same card silently
# discards whatever that other write did, and both report success.
#
# WRITTEN RED.

use strict;
use warnings;

use Fcntl qw(:flock);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-09T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'A writer with no lock of its own', dir => $root, columns => ['Backlog, Doing'] );
$tira->person_add( project => $root, id => 'michael', name => 'Michael' );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Contended' );

sub lock_held {
    my ($project) = @_;
    open my $probe, '>>', File::Spec->catfile( $project, '.tira', '.lock' ) or die $!;
    my $free = flock( $probe, LOCK_EX | LOCK_NB );
    flock( $probe, LOCK_UN ) if $free;
    close $probe;
    return $free ? 0 : 1;
}

my %common = ( project => $root, type => 'ticket', ref => $card->{ref} );

my $evidence = $tira->evidence_add( author => 'michael', %common, summary => 'Proof' );
my $gate     = $tira->gate_add( author => 'michael', %common, gate => 'Review', result => 'pass', details => 'Looked over' );

# --- the same technique t/53 already uses for every other writer -------------

my ( %during, $watching );
{
    no warnings 'redefine';
    my $original = \&Tira::_replace_record;
    local *Tira::_replace_record = sub {
        my ( $self, %args ) = @_;
        $during{$watching} = lock_held( $args{project} // $root );
        return $original->( $self, %args );
    };

    for my $case (
        [ evidence_annotate => sub {
            $tira->evidence_annotate( author => 'michael', %common, id => $evidence->{id}, note => 'Checked twice' ) } ],
        [ gate_annotate => sub {
            $tira->gate_annotate( author => 'michael', %common, id => $gate->{id}, note => 'Confirmed' ) } ],
    ) {
        my ( $name, $run ) = @{$case};
        $watching = $name;
        $run->();
        ok( $during{$name}, "$name holds the project lock while it reads and writes" );
    }
}
ok( !lock_held($root), 'and both released it' );

# --- uncontended behaviour is unchanged ---------------------------------------

my $record = $tira->record_show(%common);
is( scalar @{ $record->{evidence}[0]{annotations} }, 1, 'the evidence annotation landed' );
is( $record->{evidence}[0]{annotations}[0]{note}, 'Checked twice', 'with the right text' );
is( scalar @{ $record->{gate_passing_log}[0]{annotations} }, 1, 'the gate annotation landed' );

# --- the refusals are unchanged -----------------------------------------------

eval { $tira->evidence_annotate( author => 'michael', %common, id => 'EVD-999', note => 'x' ) };
like( $@, qr/not found/i, 'annotating an unknown id still refuses' );

eval { $tira->evidence_annotate( author => 'michael', %common, id => $evidence->{id}, note => '' ) };
like( $@, qr/note is required/i, 'an empty note still refuses' );

done_testing();

__END__

=head1 NAME

t/731-a-writer-with-no-lock-of-its-own.t - evidence.annotate and gate.annotate
hold the project lock across their read-modify-write, like every sibling

=head1 DESCRIPTION

TKT-731. C<_annotate_log> read a card, mutated it in memory and wrote it
back with no C<_with_project_lock> anywhere in it or in its two callers,
C<evidence_annotate> and C<gate_annotate> - the only two of twenty-three
C<_replace_record> call sites that did not hold it. t/53 already proves
this same discipline for every sibling writer (C<comment_add>,
C<checklist_add>, C<gate_add>, C<evidence_add>, ...); this file extends
that exact technique to the two it missed.

Because C<_replace_record> writes the whole record, the fault was not
confined to annotations: an annotate racing any other card write silently
discarded that write, and both reported success.

=cut
