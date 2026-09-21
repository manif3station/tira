#!/usr/bin/env perl
# TKT-1081. t/70-doc-examples.t's attempt() runs every documented CLI example
# in-process - no fork, Tira::CLI->run called directly - so a newly
# documented example with the same shape as job.start/dashboard/
# policy.bridge (spawns a server, loops forever) hangs the whole suite
# silently. Every skip-list entry so far (job.start/job.feeder/job.run,
# dashboard*, policy.bridge) was found reactively, by the suite actually
# hanging first and someone root-causing it afterward - there is no
# proactive signal that a NEW command needing the same treatment has been
# documented, before it hangs the suite again.
#
# t/lib/Deadline.pm's run_with_deadline() is the fix: a bounded SIGALRM
# around the in-process call, so a hang becomes a fast, named failure
# instead. This proves the mechanism itself against a genuine, guaranteed
# hang (an infinite loop, not a slow-but-finishing call) - the same
# guarantee attempt() now leans on for every documented example.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;
use Time::HiRes qw(time);

use lib 't/lib';
use Deadline qw(run_with_deadline);

# --- a genuine hang is caught fast, not left to run forever -----------------

my $started = time();
my $died = eval {
    run_with_deadline( 1, sub { my $n = 0; $n++ while 1; return $n }, 'a synthetic infinite loop' );
    1;
};
my $elapsed = time() - $started;

ok( !$died, 'a genuine hang does not fall through as a normal return' );
like( $@, qr/TKT-1081/, 'and the death names this ticket' );
like( $@, qr/a synthetic infinite loop/, 'and the label identifying which call hung' );
cmp_ok( $elapsed, '<', 5, 'and it took seconds, not forever - the deadline actually fired' );

# --- a call that finishes well inside the deadline is unaffected ------------

my $normal = run_with_deadline( 5, sub { return 'answer' }, 'a normal call' );
is( $normal, 'answer', 'a call that finishes in time returns its real result, untouched' );

# --- a call that dies for its own reason is not mistaken for a timeout ------

eval { run_with_deadline( 5, sub { die "a real error, nothing to do with time\n" }, 'a failing call' ) };
like( $@, qr/a real error, nothing to do with time/,
    'a call that fails on its own merits reports its own error, not the deadline message' );

# --- attempt() itself is actually wrapped, not just the mechanism proven ----
#
# The mechanism above proves nothing about whether t/70 actually uses it -
# read directly, the same way t/969 reads gate-run's own script text rather
# than trusting a description of it.

my $source = do {
    local $/;
    open my $fh, '<', 't/70-doc-examples.t' or die $!;
    <$fh>;
};
like( $source, qr/\bDeadline\b/, "t/70-doc-examples.t actually uses Deadline, not just a description of it" );

# Codex review: matching run_with_deadline anywhere in the file (an unused
# import, or a mention in a comment) would satisfy a bare presence check
# without proving the call this ticket is actually about is wrapped by it.
# Scoped to the one call site that matters: Tira::CLI->run's own argument
# list has to appear INSIDE a run_with_deadline(...) call, not merely
# somewhere in the same file.
like( $source, qr/run_with_deadline\s*\([^;]*Tira::CLI->run/s,
    "...specifically wrapping the Tira::CLI->run call site, not just present somewhere in the file" );

done_testing;

__END__

=head1 NAME

1138-a-hang-with-nothing-outside-to-kill-it.t - an in-process hang gets a
bounded, named failure instead of running forever

=head1 DESCRIPTION

TKT-1081. C<t/70-doc-examples.t>'s C<attempt()> runs every documented CLI
example in-process, with no child process a harness could kill from
outside - so a newly-documented example shaped like C<job.start>,
C<dashboard>, or C<policy.bridge> (spawns a server, loops forever) hangs the
whole suite silently, discoverable only by someone noticing the run never
finished.

C<t/lib/Deadline.pm>'s C<run_with_deadline()> wraps such a call in
C<alarm()>, so a genuine hang becomes a fast failure naming which call hung,
rather than an indefinite wait. This proves the mechanism against a real,
guaranteed hang (an infinite loop), confirms a normal call and a call that
fails on its own merits are both unaffected, and confirms C<attempt()>
itself was actually changed to use it - not just that the mechanism exists
somewhere unused.

=cut
