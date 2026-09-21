package Deadline;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(run_with_deadline);

# TKT-1081. t/70-doc-examples.t runs every documented CLI example in-process
# (no fork - Tira::CLI->run called directly), so a newly-documented example
# with the same shape as job.start/dashboard/policy.bridge (spawns a server,
# loops forever) hangs the whole suite silently, with nothing to catch it
# short of someone noticing the run never finished. Every prior instance of
# that shape was found reactively, by the suite actually hanging first.
#
# A bounded SIGALRM around the call converts that into a fast, named failure
# instead. alarm() is POSIX/Unix-only, which this project's test suite
# already assumes throughout (Docker-only, Linux containers).
sub run_with_deadline {
    my ( $seconds, $code, $label ) = @_;
    $label //= 'the call';

    my $result;
    my $died;
    {
        local $SIG{ALRM} = sub { die "TKT-1081: $label ran longer than ${seconds}s - treat this as a hang, not a slow pass\n" };

        # Codex review: an unconditional alarm(0) here cancels a CALLER's own
        # outer alarm too, not just this call's own - safe today (t/70 sets
        # no alarm of its own) but a trap for the next caller who nests this
        # under one. alarm() itself returns the seconds remaining on
        # whatever was already armed (0 if nothing was), so that is what
        # gets restored, rather than always clearing to 0.
        my $previous_remaining = alarm($seconds);
        $died = !eval { $result = $code->(); 1 };
        my $error = $@;
        alarm($previous_remaining);
        die $error if $died;
    }
    return $result;
}

1;

__END__

=head1 NAME

Deadline - a bounded, signal-based timeout for an in-process call

=head1 SYNOPSIS

    use lib 't/lib';
    use Deadline qw(run_with_deadline);

    my $out = run_with_deadline( 5, sub { some_call() }, 'tira.dashboard' );

=head1 DESCRIPTION

Wraps a coderef in C<alarm($seconds)> and a C<$SIG{ALRM}> handler that dies
naming the timeout, rather than letting an in-process call (one with no
child process a harness could kill from outside) hang forever. Whatever
alarm state existed before this call - none, or a caller's own outer
deadline already counting down - is restored before returning or
re-raising, on both the timeout path and the normal one. The restored
value is the seconds that were remaining when this call started, not
adjusted for time actually spent inside it, so a caller nesting this under
its own deadline gets its timer back rather than losing it, though not to
the exact second.

=cut
