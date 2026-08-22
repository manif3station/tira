#!/usr/bin/env perl

use strict;
use warnings;

use Fcntl qw(:flock);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-08T09:00:00Z' } );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Locked', dir => $root, columns => ['Backlog, Doing'] );
$tira->person_add( project => $root, id => 'michael', name => 'Michael' );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Contended' );

# Whether the lock is held, asked the only way that gives a straight answer:
# a second handle in this process is a second lock entry, so if it cannot be
# taken without blocking, somebody is holding it.
sub lock_held {
    my ($project) = @_;
    open my $probe, '>>', File::Spec->catfile( $project, '.tira', '.lock' ) or die $!;
    my $free = flock( $probe, LOCK_EX | LOCK_NB );
    flock( $probe, LOCK_UN ) if $free;
    close $probe;
    return $free ? 0 : 1;
}

ok( !lock_held($root), 'the lock is free when nothing is running' );

# Reentrancy, under an alarm so a deadlock fails the test instead of hanging
# the suite forever.
{
    local $SIG{ALRM} = sub { die "deadlocked\n" };
    alarm 20;
    my $result = eval {
        $tira->_with_project_lock( $root, sub {
            return $tira->_with_project_lock( $root, sub {
                return lock_held($root) ? 'held throughout' : 'lost';
            } );
        } );
    };
    my $error = $@;
    alarm 0;
    is( $error, '', 'a locked operation can take the lock again without deadlocking' );
    is( $result, 'held throughout', 'and the lock is still held inside the nested call' );
}
ok( !lock_held($root), 'and released once both have finished' );

# A different project is a different lock, so nesting must really take it.
my $other = File::Spec->catdir( $tmp, 'other' );
$tira->project_new( name => 'Other', dir => $other, columns => ['Backlog, Doing'] );
{
    local $SIG{ALRM} = sub { die "deadlocked\n" };
    alarm 20;
    my $inner = eval {
        $tira->_with_project_lock( $root, sub {
            return $tira->_with_project_lock( $other, sub { return lock_held($other) } );
        } );
    };
    alarm 0;
    is( $@, '', 'nesting across two projects does not deadlock' );
    ok( $inner, 'and the second project is really locked, not assumed' );
}
ok( !lock_held($other), 'and that lock is released too' );

# A failure inside a nested operation must not leave the lock or the journal.
{
    my $failed = eval {
        $tira->_with_project_lock( $root, sub {
            $tira->_with_project_lock( $root, sub { die "inner failure\n" } );
        } );
        0;
    };
    like( $@, qr/inner failure/, 'a nested failure is reported' );
    ok( !lock_held($root), 'and the lock is released' );
}

# Every method that reads then writes must hold the lock while it does both:
# the read is half the race, so wrapping only the write would fix nothing.
my %common = ( project => $root, type => 'ticket', ref => $card->{ref} );
my ( %during, $watching, $comment, $item );
{
    no warnings 'redefine';
    my $original = \&Tira::_replace_record;
    local *Tira::_replace_record = sub {
        my ( $self, %args ) = @_;
        $during{$watching} = lock_held( $args{project} // $root );
        return $original->( $self, %args );
    };

    for my $case (
        [ comment_add => sub { $comment = $tira->comment_add( %common, author => 'michael', text => 'First' ) } ],
        [ comment_update => sub { $tira->comment_update( author => 'michael', %common, comment => $comment->{id}, text => 'Edited' ) } ],
        [ checklist_add => sub { $item = $tira->checklist_add( author => 'michael', %common, item => 'A step', status => 'Open' ) } ],
        [ checklist_update => sub { $tira->checklist_update( author => 'michael', %common, id => $item->{id}, status => 'Done',
            command => ['did the step'], proof => ['step done'] ) } ],
        [ gate_add => sub { $tira->gate_add( author => 'michael', %common, gate => 'Review', result => 'pass', details => 'Looked over' ) } ],
        [ evidence_add => sub { $tira->evidence_add( author => 'michael', %common, summary => 'Proof' ) } ],
        [ comment_remove => sub { $tira->comment_remove( %common, comment => $comment->{id} ) } ],
    ) {
        my ( $name, $run ) = @{$case};
        $watching = $name;
        $run->();
        ok( $during{$name}, "$name holds the project lock while it reads and writes" );
    }
}
ok( !lock_held($root), 'and every one of them released it' );

# The record really did change, so the lock did not cost correctness.
my $final = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
is( scalar @{ $final->{comments} }, 0, 'the comment was added, edited and removed' );
is( scalar @{ $final->{checklist} }, 1, 'the checklist item survived' );
is( $final->{checklist}[0]{status}, 'Done', 'and was ticked' );
is( scalar @{ $final->{gate_passing_log} }, 2,
    'the gate entry survived, alongside the one checklist_update logged for its own proof' );

done_testing;

__END__

=head1 NAME

53-lock.t - mutations that bypassed the project lock

=head1 DESCRIPTION

Comments, checklists, gates and evidence read a record, change it in
memory and write it back. Without the project lock that is a
read-modify-write with no exclusion, and two comments added at the same
moment lose one silently, while the manual promised every mutation was
serialised. Proves the lock is now reentrant, so those methods can hold
it across the read as well as the write without deadlocking against
themselves, that nesting across two projects still takes both, and that
a failure inside a nested operation releases what it held.

=cut
