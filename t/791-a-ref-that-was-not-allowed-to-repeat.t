#!/usr/bin/env perl
# TKT-791. lib/Tira/CLI.pm's generic batch-ref guard refuses "Multiple refs
# are only available on show" for any command outside a small whitelist
# (record.show, tasklist.next, release.record) - but notify.record and
# tasklist.task.ref.link/unlink are documented with a repeatable --ref, and
# their own dispatch branches already read $option->{ref_list} directly
# (never $args{refs}, the thing the batch-ref guard actually builds). So the
# guard's early "die" refused a call before dispatch, which would have
# handled it correctly, was ever reached.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    project => $root, name => 'Batched', dir => $root,
    members => ['claude'], columns => ['backlog, implement, done'],
    sow_prefix => 'BAS', epic_prefix => 'BAE', ticket_prefix => 'BAT',
);
my $a = $tira->create_record( project => $root, type => 'ticket', title => 'a', author => 'claude' );
my $b = $tira->create_record( project => $root, type => 'ticket', title => 'b', author => 'claude' );
my $task = $tira->tasklist_add( project => $root, text => 'link me to two cards' );

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    my $status = Tira::CLI->run( command => $command, tira => $tira, argv => \@argv );
    return ( $status, $out, $err );
}

# --- tasklist.task.ref.link with two --ref, matching its own usage line ----

my ( $status, undef, $err ) = cli( 'tasklist.task.ref.link',
    '--id', $task->{id}, '--ref', $a->{ref}, '--ref', $b->{ref} );
is( $status, 0, 'tasklist.task.ref.link accepts two --ref values, matching its documented usage line' )
  or diag("refused: $err");

my ($shown) = grep { $_->{id} eq $task->{id} } @{ $tira->tasklist_list( project => $root ) };
is_deeply( [ sort @{ $shown->{refs} } ], [ sort( $a->{ref}, $b->{ref} ) ],
    'and both refs actually landed' );

# --- tasklist.task.ref.unlink with two --ref -------------------------------

( $status, undef, $err ) = cli( 'tasklist.task.ref.unlink',
    '--id', $task->{id}, '--ref', $a->{ref}, '--ref', $b->{ref} );
is( $status, 0, 'tasklist.task.ref.unlink accepts two --ref values too' )
  or diag("refused: $err");

($shown) = grep { $_->{id} eq $task->{id} } @{ $tira->tasklist_list( project => $root ) };
is_deeply( $shown->{refs}, [], 'and both were removed' );

# --- notify.record with two --ref ------------------------------------------

( $status, undef, $err ) = cli( 'notify.record',
    '--ref', $a->{ref}, '--ref', $b->{ref}, '--column', 'implement' );
is( $status, 0, 'notify.record accepts two --ref values' )
  or diag("refused: $err");

# --- the control: a command outside this set still refuses -----------------

( $status, undef, $err ) = cli( 'required-action.update',
    '--ref', $a->{ref}, '--ref', $b->{ref}, '--id', 'REQ-001', '--status', 'done' );
isnt( $status, 0, 'a command NOT in the expanded set still refuses a repeated --ref' );
like( $err, qr/Multiple refs are only available on show/,
    'with the existing, unchanged message' );

done_testing();

__END__

=head1 NAME

t/791-a-ref-that-was-not-allowed-to-repeat.t - notify.record and
tasklist.task.ref.link/unlink accept the repeatable --ref they document

=head1 DESCRIPTION

TKT-791. C<lib/Tira/CLI.pm>'s generic batch-ref guard refused a repeated
C<--ref> for any command outside C<record.show>/C<tasklist.next>/
C<release.record> - but C<notify.record> and C<tasklist.task.ref.link>/
C<unlink> already document a repeatable C<--ref> in their own usage lines,
and their dispatch branches already read C<$option-E<gt>{ref_list}> directly
rather than the C<$args{refs}> the guard builds. The guard's early refusal
fired before dispatch was ever reached, so a call matching the documented
usage line was refused anyway.

Fixed by widening the whitelist to include the three commands whose
dispatch already handles multiple refs correctly. A command outside that
set is unaffected - the control above proves it.

=cut
