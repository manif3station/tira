#!/usr/bin/env perl
# TKT-959, split from TKT-950 CHK-006. t/509 executes tira.job.help's 68
# worked examples from the test harness - an interactive shell's PATH, not
# the PATH a job's own executor runs with. d2 resolves through PATH and lives
# in ~/perl5/bin, a local::lib directory a daemon or a Starman worker need
# not have.
#
# This exercises the ONE executor this card actually reaches:
# run_due_commands/run_due_job, the police daemon's job-due path
# (lib/Tira/CLI/Police.pm). It does NOT cover a Starman web worker's own
# exec environment, or any other process that might one day run a job -
# stated here rather than left to be assumed, since a test that covers one
# executor and reads as covering all of them is the overclaim TKT-950 itself
# was about.
#
# WRITTEN RED: run_due_job execs @command directly via IPC::Open3 with no
# shell - PATH resolution is Perl's exec(), which this test controls exactly
# the way a restricted daemon environment would.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI::Police;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $now  = '2026-09-07T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Exec Path', dir => $root, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'EPS', epic_prefix => 'EPE', ticket_prefix => 'EPT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    $tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ), \$now );
}

sub recent_of {
    my ( $tira, $root, $id ) = @_;
    my ($job) = grep { $_->{id} eq $id } @{ $tira->job_list( project => $root ) };
    return join "\n", @{ $job->{recent} || [] };
}

sub run_pass {
    my ( $tira, $root, $store ) = @_;
    return $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
}

# A fake local::lib bin directory, standing in for ~/perl5/bin: a d2 that
# actually runs, so the "PATH includes it" half of this test does not depend
# on the real d2 or the real board being reachable from inside a container.
my $bin = tempdir( CLEANUP => 1 );
my $fake_d2 = File::Spec->catfile( $bin, 'd2' );
open my $fh, '>', $fake_d2 or die $!;
print {$fh} "#!/bin/sh\necho fake-d2-ran: \"\$@\"\nexit 0\n";
close $fh;
chmod 0755, $fake_d2;

my $bare_path = '/usr/bin:/bin';
my $with_bin  = "$bin:/usr/bin:/bin";

# --- restricted PATH: the documented example cannot exec --------------------

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *', command => 'd2 tira.police.outstanding' );
    ${$clock} = '2026-09-07T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );

    local $ENV{PATH} = $bare_path;
    Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    my $recent = recent_of( $tira, $root, 'JOB-001' );
    like( $recent, qr/No such file or directory|d2:/i,
        'with a PATH lacking the local::lib bin directory, the job.help-documented bare d2 example cannot start' );
}

# --- the same PATH the example needs: it works -------------------------------

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *', command => 'd2 tira.police.outstanding' );
    ${$clock} = '2026-09-07T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );

    local $ENV{PATH} = $with_bin;
    Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    my $recent = recent_of( $tira, $root, 'JOB-001' );
    like( $recent, qr/fake-d2-ran: tira\.police\.outstanding/,
        'and with it on PATH, the same documented example runs through the real job-due executor' );
    unlike( $recent, qr/No such file or directory|could not start/i,
        'with no trace of the restricted-PATH failure left behind' );
}

# --- what this test does and does not cover ----------------------------------

my $note = 'COVERS: run_due_commands/run_due_job, the police-daemon job-due '
  . 'exec path used by JOB-due commands on this board. DOES NOT COVER: a '
  . 'Starman web worker exec-ing a job, or any other future executor - '
  . 'those would need their own PATH environment proven the same way.';
ok( length($note), $note );

done_testing();

__END__

=head1 NAME

593-an-exec-path-instead-of-a-harness.t - a job.help example run the way a
job actually runs it

=head1 DESCRIPTION

TKT-959, split from TKT-950 CHK-006: C<t/509> proves C<tira.job.help>'s 68
worked examples from the test harness's own PATH, not from the PATH a job's
real executor runs with. C<d2> resolves through C<PATH> and lives in
C<~/perl5/bin>, a C<local::lib> directory a daemon or a Starman worker need
not have.

This runs the documented bare-C<d2> example through C<run_due_commands> /
C<run_due_job> - the one executor this card actually reaches, the police
daemon's job-due path - twice: once with a restricted C<PATH> lacking the
C<local::lib> bin directory, confirming the job says plainly it could not
start (TKT-950's own fix), and once with it present, confirming the same
example runs cleanly. It states explicitly which executor is covered and
which is not, rather than reading as proof for every executor a job could
ever run under.

=cut
