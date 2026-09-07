#!/usr/bin/env perl
# TKT-1002. tira.job.help's own worked example for a command-mode job is a
# bare "d2 tira.police.outstanding" (--command "d2 tira.police.outstanding").
# The job daemon runs that string with no shell, via IPC::Open3::open3
# (run_due_job, lib/Tira/CLI/Police.pm), which does not inherit an
# interactive shell's PATH - so the very example the document teaches fails
# to start when the daemon actually runs it. Measured live: JOB-005, an exact
# copy of the documented example, failed every scheduled run with
# "exec of d2 tira.police.outstanding failed: No such file or directory",
# while the identical command worked fine typed into a terminal.
#
# THE FIX IS DOCUMENTATION, NOT CODE (decided and recorded on the card): the
# worked examples themselves are left exactly as they are - they are correct
# and portable for a human or agent typing them, and t/509 already proves
# every one of them runs from an interactive PATH. What was missing is the
# warning that the STRING PASSED AS --command is executed a second time, by
# the daemon, in an environment that does not resolve `d2` the way a login
# shell does - so docs/JOBS.md must say this, in the section that already
# explains what a command may contain, and lib/Tira/CLI/Police.pm's
# run_due_job must point back at it.
#
# WRITTEN RED.

use strict;
use warnings;

use lib 't/lib';
use Suite ();
use Test::More;

my $doc = 'docs/JOBS.md';
open my $fh, '<:raw', $doc or die "$doc: $!";
my $text = do { local $/; <$fh> };
close $fh;

# --- the gap itself is named, in the section that already covers commands ---

like(
    $text,
    qr/PATH/,
    'the document says the word a reader searches for when a job command '
      . 'fails to start'
);

like(
    $text,
    qr/daemon/i,
    'and names who actually runs a command job - not the interactive shell '
      . 'that ran the d2 job.add typing it in'
);

like(
    $text,
    qr/no shell|does not inherit|not an interactive/i,
    'and says why: the daemon\'s own exec environment is not a login shell\'s, '
      . 'which is the fact the PATH gap follows from'
);

# --- the reader is given something to do about it, not just a warning -------

like(
    $text,
    qr/absolute path/i,
    'the reader is told the concrete fix: an absolute path in --command, '
      . 'not a bare program name the daemon has to find on its own'
);

like(
    $text,
    qr/which d2|resolve.*once/i,
    'and how to find that absolute path, once, rather than guessing at one'
);

# --- the worked examples themselves are untouched (t/509's own contract) ----
#
# Rewriting every "d2 ..." example to a hardcoded absolute path would fix
# nothing (the path is only ever true on the machine that measured it) and
# would break t/509's own claimed-vs-actual example count, which counts every
# line starting literally with "d2 tira.". The fix is prose alongside the
# examples, not a rewrite of them - checked here so this file itself does not
# reintroduce the shape-of-absence trap t/509 already guards against.

my ($claimed) = $text =~ /\*\*(\d+) worked examples\*\*/;
my %shown;
$shown{$1} = 1 while $text =~ /^\s*(d2 tira\.[^\n]*)$/mg;
is( $claimed, scalar keys %shown,
    'the worked-example count still matches what is actually there - this '
      . 'fix added guidance, not a new or rewritten example' );

# --- the code side points back at the doc, so a reader of run_due_job finds -
# --- the explanation rather than rediscovering it from a failed job --------

my $police = Suite::cli_source();

like(
    $police,
    qr/run_due_job/,
    'sanity: the module still has the sub this card is about'
);

my ($near_run_due_job) = $police =~ /(.{0,1200})sub run_due_job/s;

like(
    $near_run_due_job,
    qr/JOBS\.md/,
    'the comment immediately above run_due_job cross-references docs/JOBS.md, '
      . 'so a reader here is pointed at the PATH explanation rather than left '
      . 'to reconstruct it from an exec failure'
);

done_testing();

__END__

=head1 NAME

1002-a-job-with-no-path-to-itself.t - a command-mode job's own --command is
executed a second time, by the daemon, not the shell that typed it

=head1 DESCRIPTION

TKT-1002. C<tira.job.help>'s worked example for a command-mode job
(C<--command "d2 tira.police.outstanding">) is correct and runs fine typed by
a person - t/509 proves it does. What it does not say is that the STRING
inside C<--command> is executed again, later, by the job daemon itself
through C<IPC::Open3::open3> with no shell, in an exec environment that does
not carry an interactive login shell's C<PATH>. C<docs/JOBS.md> now explains
this beside its existing "what a command may contain" section, with the
concrete fix (an absolute path, found once with C<which d2>), and
C<run_due_job> in C<lib/Tira/CLI/Police.pm> carries a comment pointing back at
it. The worked examples themselves are unchanged - rewriting them to a
hardcoded absolute path would only be true on the machine that measured it,
and would silently break C<t/509>'s own claimed-example-count check.

=cut
