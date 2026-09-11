package Tira::CLI::Police::Jobs;

# The due-job execution block, lifted out of Tira::CLI::Police so a
# 1495-line file stays readable - TKT-1043, mirroring TKT-1041's own lift of
# the move-path guards and TKT-1042's lift of the browser's job providers,
# both the same week.
#
# Every function here still takes exactly the arguments it took inside
# Tira::CLI::Police - nothing closes over anything, so the lift is
# mechanical. Documentation (the free-standing comment blocks explaining WHY
# this file runs due jobs rather than the engine, and the design decisions
# behind record_run's single-recorder shape) stays in Tira::CLI::Police,
# deliberately: it explains the file's OWN concern (why execution lives in
# the CLI layer at all), not these four functions specifically.
#
# CALLED THROUGH A FORWARD OF THE SAME NAME, required at the point
# of use rather than used at the top - exactly Tira::CLI::Move's own shape.
# This one matters more than most: several existing tests monkey-patch these
# subs directly by their fully-qualified Tira::CLI::Police:: name
# (`local *Tira::CLI::Police::run_due_job = sub {...}`, t/564, t/570), and a
# forward preserves that - the override replaces the STUB, which is what
# every caller actually calls, so the override still takes effect regardless
# of where the real body now lives.
#
# The same reasoning applies one level down to internal calls: run_due_job
# and record_run are called from inside run_due_commands here BY THEIR
# FULLY-QUALIFIED Tira::CLI::Police:: NAME, not directly - an unqualified
# call would resolve to this package's own copy at compile time and skip
# the monkey-patch entirely. And $RUN_TIMEOUT itself stays declared in
# Tira::CLI::Police rather than being redeclared here, for the identical
# reason: t/512 localises it as $Tira::CLI::Police::RUN_TIMEOUT, and a
# fresh `our $RUN_TIMEOUT` in this package would be a different variable
# that local() never touches.

use strict;
use warnings;

sub record_run {
    my ( $tira, $args, $job, $outcome ) = @_;
    return $outcome if ref $outcome ne 'HASH';

    if ( $outcome->{ran} ) {
        eval { $tira->job_ran( %{ $args || {} }, id => $job->{id} ); 1; };
    }

    my @lines = grep { defined && /\S/ } split /\n/, ( $outcome->{output} // '' );
    push @lines, "exit status $outcome->{status}"
      if ( $outcome->{status} // 0 ) != 0;
    eval {
        $tira->job_feed( %{ $args || {} }, id => $job->{id}, lines => \@lines )
          if @lines;
        1;
    };
    return $outcome;
}

sub run_due_commands {
    my ( $tira, $args, $result ) = @_;
    return [] if ref $result ne 'HASH';
    my $due = $result->{due_commands} || [];
    return [] if !@{$due};

    require Tira::Job;
    require Tira::CLI::Police;
    my @ran;
    for my $job ( @{$due} ) {
        next if ( $job->{mode} // '' ) ne 'command';
        my $outcome = eval { Tira::CLI::Police::run_due_job( job => $job ) };
        if ( !$outcome ) {
            my $why = $@ || 'unknown failure';
            $why =~ s/\s+\z//;

            # FED ONTO THE JOB, not only returned. A command has two ways to
            # fail and they used to be treated very differently: one that RAN
            # and exited non-zero had its output and "exit status N" written
            # where the card shows them, by the branch just below; one that
            # NEVER STARTED had its reason pushed into this return value and
            # nothing else. Nothing displays that return value, so the card
            # showed a job that fired with no sign anything had gone wrong -
            # which is the silence the comment below says must not be rebuilt,
            # in the case where the reader has least to go on. Reported by the
            # owner as "a job command using bare d2 cannot exec", and he could
            # not have seen why from the board even once it did fail. TKT-950.
            #
            # The command is named because that is what makes it diagnosable:
            # `d2` resolves from PATH, and a daemon's PATH is not an
            # interactive shell's, so "could not start: d2 ..." reads as the
            # PATH problem it usually is.
            my $said = "could not start: $job->{command}";
            eval {
                $tira->job_feed( %{ $args || {} }, id => $job->{id},
                    lines => [ $said, $why ] );
                1;
            };
            push @ran, { id => $job->{id}, ran => 0, status => -1, output => $why };
            next;
        }

        # Recorded even when the command failed - a non-zero exit with its
        # message is exactly the run somebody needs to see, and dropping it
        # would rebuild the silence this whole epic exists to end. Through the
        # shared recorder since TKT-963, so the button records what the
        # schedule records rather than the two paths keeping their own answers
        # to the same question.
        Tira::CLI::Police::record_run( $tira, $args, $job, $outcome );
        push @ran, { id => $job->{id}, %{$outcome} };
    }
    return \@ran;
}

sub advance_monitor_output {
    my ( $tira, $args, $result ) = @_;
    return if ref $result ne 'HASH';
    my $seen = $result->{monitor_output} || [];
    require Tira::Job;

    # WHICH MONITORS THE PASS ACTUALLY REPORTED, rather than which ones the rule
    # meant to report. TKT-925: `spoke` is set from the same condition that
    # CALLS the reporter, and the reporter can return without reporting - a
    # suspended rule, a card whose finding has been declined. Draining on the
    # intention took the monitor's words off the record with nothing anywhere
    # having said them, which is the one loss this whole rule exists to prevent.
    #
    # RECORDED, NOT ANNOUNCED, and the difference is worth stating because the
    # first version of this got it wrong in two ways at once and the suite said
    # so. It required the policy's action to be bridge-reminder, which breaks a
    # log-only monitor - log-only is a rule being tuned, its findings still
    # reach the ledger and tira.police.outstanding, and its output must still
    # drain. And it refused to drain a QUIET finding, which is backwards: quiet
    # means these exact words were already announced, and a poller doing the
    # same work every minute prints the same line constantly. t/502 asserts both
    # directly.
    #
    # So the question is only whether the pass produced a finding for this
    # monitor at all. Matched on the sub_key rather than by parsing the detail,
    # because the rule already builds it as "JOB-ID:what was said" - an exact
    # key rather than a guess at the shape of a sentence.
    my %reported;
    for my $violation ( @{ $result->{violations} || [] } ) {
        next if ( $violation->{rule} // '' ) ne 'monitor-output';
        my ($id) = split /:/, ( $violation->{sub_key} // '' ), 2;
        $reported{$id} = 1 if defined $id && $id ne '';
    }

    for my $mark ( @{$seen} ) {
        next if !$mark->{spoke};
        next if !$reported{ $mark->{id} };

        # A failure to record is REPORTED, not swallowed. Silently failing here
        # means the same lines arrive again next pass, and a bridge repeating
        # itself is the noise this rule was careful to avoid.
        eval {
            Tira::Job::job_output_drain( $tira, %{$args}, id => $mark->{id},
                count => $mark->{count}, dropped => $mark->{dropped} );
            1;
        } or do {
            my $why = $@ || 'it could not be recorded';
            $why =~ s/\s+\z//;
            print {*STDERR} "could not record how far $mark->{id} has been read, "
              . "so its output may be announced again: $why\n";
        };
    }
    return;
}

# How long a command-mode job is given before the board stops waiting. Generous,
# because the cost of cutting a slow-but-working job short is a false failure on
# the bridge, and the cost of waiting is bounded now rather than infinite. A job
# that genuinely needs longer says so with its own run_timeout. TKT-864.
#
# LIVES IN Tira::CLI::Police, NOT HERE - TKT-1043. t/512 localises
# $Tira::CLI::Police::RUN_TIMEOUT by its fully-qualified name to force an
# already-passed deadline; read by that name below rather than declared fresh
# in this package, which would be a different variable the test's local()
# never touches.

# THE COMMAND BELOW IS EXEC'D WITH NO SHELL AND NO INTERACTIVE PATH. A bare
# program name that resolves fine typed into a terminal can fail here with
# "No such file or directory" - see docs/JOBS.md's "The command is executed a
# second time" section for why and the fix (an absolute path in --command).
# TKT-1002.
sub run_due_job {
    my (%args) = @_;
    my $job = $args{job};
    die "A job is required\n" if !$job;

    # A message-mode job is announced by the engine and runs nothing. Said
    # here rather than assumed by the caller, so the boundary is in one place.
    return { ran => 0, status => 0, output => '' }
      if ( $job->{mode} // '' ) ne 'command';

    # Loaded HERE rather than relying on the require in another sub of this
    # module: that one runs only if that sub is called first, which is exactly
    # the assumption that made this line die with "Undefined subroutine" the
    # moment a test reached run_due_job directly. require is idempotent, so
    # naming it at the call site costs nothing and removes the ordering.
    require Tira::Job;

    # A command that cannot be READ is reported as a failed run rather than
    # allowed to take the pass down: the bridge is the single reporting path, so
    # one malformed job command must not silence every other finding. The
    # engine's own words are carried through - they name the quote and the
    # command - instead of a generic message.
    my @command = eval { Tira::Job::job_command_words( $job->{command} ) };
    if ( my $why = $@ ) {
        $why =~ s/\s+\z//;
        return { ran => 0, status => -1, output => $why };
    }
    return { ran => 0, status => -1, output => 'the job has no command to run' }
      if !@command;

    require IPC::Open3;
    require Symbol;

    my ( $in, $out, $error ) = ( undef, Symbol::gensym(), Symbol::gensym() );
    my $pid = eval { IPC::Open3::open3( $in, $out, $error, @command ) };
    if ( !$pid ) {

        # A program that is not there is a RESULT, not a crash. The bridge is
        # told what could not be run, which is more use than silence and is
        # the same judgement _reading makes about a missing docker.
        my $why = $@ || 'could not be run';
        $why =~ s/\s+\z//;
        return { ran => 1, status => -1, output => "$command[0]: $why" };
    }

    close $in if $in;

    # BOTH HANDLES, AS THEY BECOME READY. Reading stdout to EOF first and only
    # then reading stderr deadlocks: a child that fills the stderr pipe blocks
    # writing it, never exits, and this side blocks forever waiting for stdout
    # to end - waitpid is never reached and the police bridge hangs with it.
    # The pipe buffer is around 64KB, so it takes a chatty command rather than
    # a malicious one. Caught in review before it shipped; it would have looked
    # like a job that never returned, which is precisely the silence this card
    # exists to remove.
    # AND BOUNDED, because can_read with no argument waits for ever. A child that
    # neither writes nor exits - `sleep 60`, a poll against something that has
    # stopped answering, a prompt nobody will type into - left this blocked, and
    # waitpid was never reached. The police pass never finished, so NOTHING was
    # reported: one bad command silenced the whole board.
    #
    # That is the same failure shape EPC-014 exists to end, arriving through the
    # machinery built to end it. The deadlock guarded against above is one way
    # to never return; this is the general case. TKT-864.
    #
    # The deadline is absolute rather than per-read, so a command that dribbles
    # a byte a second cannot renew it for ever.
    require IO::Select;
    require POSIX;
    require Tira::CLI::Police;
    my $limit = $job->{run_timeout} || $Tira::CLI::Police::RUN_TIMEOUT;
    my $deadline = time + $limit;
    my $timed_out = 0;

    my $select = IO::Select->new( $out, $error );
    my %text = ( "$out" => '', "$error" => '' );
    while ( $select->handles ) {
        my $left = $deadline - time;
        if ( $left <= 0 ) { $timed_out = 1; last }

        my @ready = $select->can_read($left);
        if ( !@ready ) { $timed_out = 1; last }

        for my $handle (@ready) {
            my $chunk = '';
            my $read = sysread $handle, $chunk, 65536;
            if ( !$read ) { $select->remove($handle); next }
            $text{"$handle"} .= $chunk;
        }
    }

    # KILLED, NOT ABANDONED. Returning while the child runs would leave a
    # process nothing on the board points at - the orphan TKT-869 is about -
    # and the next pass would start another beside it. TERM first because a
    # command given the chance to stop tidily usually should be.
    if ($timed_out) {
        kill 'TERM', $pid;
        my $gone = 0;
        for ( 1 .. 20 ) {
            $gone = waitpid( $pid, POSIX::WNOHANG() );
            last if $gone;
            select undef, undef, undef, 0.1;
        }
        kill 'KILL', $pid if !$gone;
    }

    close $out;
    close $error;
    waitpid $pid, 0;

    # A CHILD KILLED BY A SIGNAL IS NOT A SUCCESS. $? >> 8 alone reports 0 for
    # one - SIGKILL leaves $? as 9, and 9 >> 8 is 0 - so a job the system killed
    # would have read as having exited cleanly. That is the failure-looks-like-
    # success inversion this whole card exists to prevent, and it was sitting
    # inside the fix for it. Reported the way a shell reports it: 128 plus the
    # signal number.
    my $raw    = $?;
    my $signal = $raw & 127;
    my $status = $signal ? 128 + $signal : $raw >> 8;

    # A TIMED-OUT JOB IS NOT A SUCCESS, and it is not merely "killed" either.
    # Left to the signal arithmetic above it would read as 143 - a job somebody
    # stopped - with nothing to say the board stopped it, and a reader of the
    # bridge could not tell it from a command that failed on its own terms. So
    # the status is named and the output says so, because a pass that finishes
    # and reports nothing about this job is a hang traded for a lie.
    # OCTETS BECOME TEXT HERE, the same decision feed_from_handle makes about
    # the same kind of stream and for the same reason.
    #
    # sysread above hands back bytes. Everything downstream treats a job's
    # output as text: run_due_commands splits it into lines and gives them to
    # job_feed, and the record writer is in utf8 mode - so a byte held as a
    # character is encoded a SECOND time on the way to disk and comes back as
    # the separate Latin-1 pieces of its own UTF-8 encoding. The owner reported
    # exactly that, a shrug emoji rendered as a run of accented characters, and
    # it applies to any command output that is not pure ASCII. TKT-953.
    #
    # FB_QUIET rather than a die, matching the feeder line for line: one
    # corrupt byte in a command's output must not cost the rest of it, and a
    # command that emits something undecodable has still run and still needs
    # reporting.
    #
    # DECODED WHERE IT IS READ, not further down. A compensating decode in
    # run_due_commands or in the panel would fix the symptom for one caller and
    # leave the next one to rediscover it - and this fault exists precisely
    # because two readers of a child's output disagreed about whose job this
    # was.
    my $output = Encode::decode( 'UTF-8', $text{"$out"} . $text{"$error"},
        Encode::FB_QUIET() );
    if ($timed_out) {
        $status = -1;
        $output .= "\n" if length $output && $output !~ /\n\z/;
        $output .= "the job timed out after ${limit}s and was stopped";
    }

    return {
        ran    => 1,
        status => $status,
        output => $output,
    };
}

=head1 NAME

Tira::CLI::Police::Jobs - due-job execution for the police pass

=head1 DESCRIPTION

Four functions lifted out of C<Tira::CLI::Police>: C<record_run> (the single
recorder both a scheduled run and a manual C<Run now> click go through),
C<run_due_commands> (runs every command-mode job a pass found due),
C<advance_monitor_output> (drains a monitor's own leavings), and
C<run_due_job> (the actual executor - C<open3>, read, decode, wait).

Reached through a forward of the same name in C<Tira::CLI::Police>,
required at the point of use. Not renamed, so every existing caller -
C<Tira::CLI::Job>, and the tests that monkey-patch
C<Tira::CLI::Police::run_due_job> directly - needed no change at all.

Calls BETWEEN these functions, inside this module, go through their old,
fully-qualified C<Tira::CLI::Police::> name rather than a bare call - the
same tests that monkey-patch C<run_due_job> only override the glob on
C<Tira::CLI::Police>, and an unqualified call from C<run_due_commands>
would resolve to this package's own copy instead. C<$RUN_TIMEOUT> stays
declared in C<Tira::CLI::Police> for the identical reason: a test
localises it by that fully-qualified name.

=head1 SEE ALSO

L<Tira::CLI::Police>

=cut

1;
