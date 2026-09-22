#!/usr/bin/env perl
# TKT-1093. tira.job.add accepted a --command whose first word was a bare,
# non-absolute executable name with no check that it would actually
# resolve when the job daemon later ran it: run_due_job execs a job's
# command with no shell and no interactive PATH (documented, TKT-1002/959,
# docs/JOBS.md), so a name that only resolves under an interactive shell's
# PATH silently failed with ENOENT every time the job fired - discovered
# live as JOB-008 on the developer-dashboard project's own board
# ("d2 check-tickets"). Corrected diagnosis (this card's own comment):
# job_command_words splits the string correctly; the real gap is that
# job.add never checked whether the resolved word would actually run.
#
# THE FIX IS A WARNING, NOT A REFUSAL - the card's own scope. A caller who
# genuinely wants an unresolvable command (e.g. one that will exist by the
# time the job first fires) is not blocked; they are told, at the moment
# they can still act on it, rather than finding out only when the job
# fails on schedule.
#
# WRITTEN RED.

use strict;
use warnings;

use Cwd ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub { '2026-09-22T00:00:00Z' } );
$tira->project_new( name => 'Jobs', dir => $root, members => ['claude'] );

sub job_add_cli {
    my (@argv) = @_;
    local $ENV{TIRA_HOME} = $root;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run(
        command => 'job.add', argv => \@argv, tira => $tira,
    );
    return ( $status, $out, $err );
}

# --- a bare, non-absolute name that does not resolve on this PATH ----------

{
    my ( $status, $out, $err ) = job_add_cli(
        '--schedule', '0 * * * *',
        '--command', 'a-name-nothing-on-this-machine-provides-1148' );
    is( $status, 0, 'the job is still created - this is a warning, not a refusal' );
    like( $err, qr/a-name-nothing-on-this-machine-provides-1148/,
        'and the warning names the unresolvable word' );
    like( $err, qr/not.*(?:an absolute|resolvable|resolve)/i,
        'and says what is wrong with it, not just that something is wrong' );
}

# --- an absolute path is never warned about, whether or not it exists ------
#
# job.add cannot know if a path will exist by the time the job first fires
# (that is exactly the "will exist later" case scope excludes touching) -
# only a BARE name unqualified by any directory is checked.

{
    my ( $status, $out, $err ) = job_add_cli(
        '--schedule', '0 * * * *',
        '--command', '/not/anywhere/real/but/absolute' );
    is( $status, 0, 'an absolute path is accepted' );
    unlike( $err, qr/not.*(?:an absolute|resolvable|resolve)/i,
        'and never warned about, even though it does not exist either' );
}

# --- a bare name that DOES resolve on this PATH is not warned about --------

{
    my ( $status, $out, $err ) = job_add_cli(
        '--schedule', '0 * * * *', '--command', 'perl' );
    is( $status, 0, 'a bare name that resolves is accepted' );
    unlike( $err, qr/not.*(?:an absolute|resolvable|resolve)/i,
        'and not warned about - perl is on this PATH' );
}

# --- a message-only job (no --command that runs) is unaffected -------------

{
    my ( $status, $out, $err ) = job_add_cli(
        '--schedule', '0 * * * *', '--message', 'watch something' );
    is( $status, 0, 'a message-only job is still accepted' );
    is( $err, '', 'and nothing is warned about - there is no command to check' );
}

# --- a RELATIVE path (containing a separator, not just a leading one) ------
# is also never checked - exec resolves it directly, the same as an
# absolute path, rather than searching PATH for it (Codex review).

{
    my ( $status, $out, $err ) = job_add_cli(
        '--schedule', '0 * * * *', '--command', './nowhere/real/but-relative' );
    is( $status, 0, 'a relative path is accepted' );
    unlike( $err, qr/not.*(?:an absolute|resolvable|resolve)/i,
        'and never warned about either, even though it does not exist' );
}

# --- an unbalanced quote in --command warns nothing rather than crashing ---
# job_command_words can die on this; the failure must stay contained to
# "no warning printed", not propagate as an uncaught exception after
# job_add has already succeeded (Codex review).

{
    my ( $status, $out, $err ) = job_add_cli(
        '--schedule', '0 * * * *', '--command', q{echo "unterminated} );
    is( $status, 0, 'a command with an unbalanced quote is still accepted, not a fatal CLI error' );
}

# --- a directory on PATH sharing the bare word's name is not mistaken for
# an executable file (Codex review: -x alone is true for a directory too)

{
    my $tmp2 = tempdir( CLEANUP => 1 );
    mkdir File::Spec->catdir( $tmp2, 'a-directory-not-a-program-1148' );
    local $ENV{PATH} = $tmp2;
    my ( $status, $out, $err ) = job_add_cli(
        '--schedule', '0 * * * *', '--command', 'a-directory-not-a-program-1148' );
    is( $status, 0, 'the job is still created' );
    like( $err, qr/a-directory-not-a-program-1148/,
        'and a same-named directory on PATH is not mistaken for a runnable program' );
}

# --- a trailing empty PATH segment means "current directory", the same as
# an interior one - conventionally, split() alone silently drops it
# (Codex review).

{
    my $tmp3 = tempdir( CLEANUP => 1 );
    my $prog = File::Spec->catfile( $tmp3, 'a-program-only-cwd-can-see-1148' );
    open my $fh, '>', $prog or die $!;
    close $fh;
    chmod 0755, $prog;
    my $cwd = Cwd::getcwd();
    chdir $tmp3 or die $!;
    local $ENV{PATH} = "/nonexistent-1148:";    # trailing empty segment = cwd
    my ( $status, $out, $err ) = job_add_cli(
        '--schedule', '0 * * * *', '--command', 'a-program-only-cwd-can-see-1148' );
    chdir $cwd or die $!;
    is( $status, 0, 'the job is still created' );
    unlike( $err, qr/a-program-only-cwd-can-see-1148/,
        "and a program the trailing empty PATH segment's cwd meaning would find is not warned about" );
}

# --- a completely empty $ENV{PATH} (not just an empty segment within it)
# still means "current directory" - split(..., -1) on a totally empty
# string returns zero fields in Perl, not one empty-string field, so this
# needs its own explicit handling (Codex review, round 2).

{
    my $tmp4 = tempdir( CLEANUP => 1 );
    my $prog = File::Spec->catfile( $tmp4, 'a-program-empty-path-finds-1148' );
    open my $fh, '>', $prog or die $!;
    close $fh;
    chmod 0755, $prog;
    my $cwd = Cwd::getcwd();
    chdir $tmp4 or die $!;
    local $ENV{PATH} = '';
    my ( $status, $out, $err ) = job_add_cli(
        '--schedule', '0 * * * *', '--command', 'a-program-empty-path-finds-1148' );
    chdir $cwd or die $!;
    is( $status, 0, 'the job is still created' );
    unlike( $err, qr/a-program-empty-path-finds-1148/,
        'and a program a completely empty $ENV{PATH} would find via cwd is not warned about' );
}

done_testing;

__END__

=head1 NAME

1148-a-name-nothing-can-reach.t - tira.job.add warns when --command's first
word will not resolve when the daemon runs it

=head1 DESCRIPTION

TKT-1093. The daemon execs a job's C<--command> with no shell and no
interactive PATH, so a bare (non-absolute) first word that only resolves
under an interactive shell's own PATH used to be accepted silently and
fail with ENOENT every time the job fired. C<tira.job.add> now checks the
command's first word against the process's own C<$ENV{PATH}> (the same
environment the daemon itself execs under) and prints a warning - not a
refusal - naming the word when it will not resolve. An absolute path is
never checked, since job.add cannot know whether a path will exist by the
time the job first fires.

=cut
