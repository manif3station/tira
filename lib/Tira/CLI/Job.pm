package Tira::CLI::Job;

# The four repeated-job verbs, kept out of Tira::CLI for the reason every
# other concern module here exists: the index says a thing exists and where,
# and does not hold it. Adding these inline took lib/Tira/CLI.pm to 3,028
# lines and t/430 refused it at 3,000 - the guard doing its job rather than
# an obstacle to route around by raising the number.
#
# THE REFUSAL FOR A MALFORMED SCHEDULE IS NOT HERE. It comes from
# Tira::Job::_cron_parse, and this module only surfaces it. Two validators
# for one format is how the engine and the browser ended up disagreeing
# about attachment content types (TKT-713), and TKT-843 will meet the same
# temptation in JavaScript. EPC-014, TKT-837.

use strict;
use warnings;

# How many lines the feeder gathers before writing, and how long it will wait
# for more before writing what it has anyway.
#
# The pair exists because a monitor is two opposite problems at once. A chatty
# poller writing every line would take the project lock hundreds of times a
# minute; a monitor that speaks once an hour must not wait for a batch that will
# not fill for a day. The count answers the first, the timeout the second, and
# the timeout is short because being heard late is the failure this epic is
# about - the cost of a needless wake-up is one lock nobody was contending for.
our $BATCH_LINES          = 25;
our $QUIET_AFTER_SECONDS  = 2;

# --command is shared with required-action proofs, which take it repeatably as
# 'command=s@'. Declaring a second 'command=s' for jobs is what t/450 refuses:
# Getopt::Long prints "Duplicate specification" to STDERR on every invocation,
# and TKT-576 records the last time that shipped. So the array form is read
# here instead. Two of them is refused rather than silently taking one - a job
# runs exactly one command, and quietly dropping the other is the same fault
# the whole option guard above exists to prevent.
sub _command_of {
    my ($option) = @_;
    my $given = $option->{command};
    return undef if !defined $given;
    return $given if !ref $given;
    return undef if !@{$given};
    die "A job runs one command - give --command once, not " . scalar( @{$given} ) . " times\n"
      if @{$given} > 1;
    return $given->[0];
}

# Anything that is not recognisably true was previously false, so
# --enabled banana quietly disabled a job and said nothing. That is the "a
# wrong flag that parses looks accepted" fault the option guard two files away
# exists to prevent, and this board refuses the same shape everywhere else: a
# checklist status of 'todo' is refused rather than guessed, and a malformed
# cron is refused rather than treated as never-due. Found by a documentation
# review before it shipped, which is why the accepted words are now a list
# rather than a regex with an implicit else.
my %ENABLED = (
    ( map { $_ => 1 } qw(1 yes true on) ),
    ( map { $_ => 0 } qw(0 no false off) ),
);

sub _enabled_of {
    my ($given) = @_;
    my $value = $ENABLED{ lc $given };
    die "Unknown --enabled value '$given' - the words that work are "
      . join( ', ', sort keys %ENABLED ) . "\n"
      if !defined $value;
    return $value;
}

# Start a monitor, and record what it started as.
#
# WHY open3 AND NOT fork/setsid/exec. A hand-rolled detach puts the child's
# redirections and its exec in a branch that only ever runs in the child
# process, where Devel::Cover cannot follow it - so the mandatory 100%
# statement gate would be met by writing the fork out again in a shape nobody
# runs, or by lowering the gate. open3 is already this codebase's spawn (see
# run_due_job) and does the forking in code that is not ours to cover. The
# monitor is reparented when this process exits, which is what "keeps running"
# needs; it is not setsid'd, and a terminal hangup would still reach it. That
# is a real difference from a daemon and is written here rather than implied.
#
# OUTPUT GOES THROUGH A PIPELINE to the feeder, which is its reader. An UNREAD
# pipe fills at about 64KB and blocks the monitor forever - the deadlock TKT-841
# was reviewed for - and until TKT-851 this said the output went to a file for
# exactly that reason. The constraint is unchanged; what satisfies it is not.

# Is this word something the system can actually run? Answered the way a shell
# answers it: a word with a slash is a path and is asked directly, a bare word is
# looked for along PATH. A directory is not a program, which -x alone would say
# yes to.
sub _command_is_runnable {
    my ($word) = @_;
    return 0 if !defined $word || $word eq '';

    require File::Spec;
    return ( -x $word && !-d $word ) ? 1 : 0 if $word =~ m{/};

    for my $dir ( File::Spec->path ) {
        my $try = File::Spec->catfile( $dir, $word );
        return 1 if -x $try && !-d $try;
    }
    return 0;
}

sub _start_monitor {
    my ( $tira, $args, $job ) = @_;

    die "Job $job->{id} is a cron job - it runs when due, and is not started\n"
      if ( $job->{schedule_kind} // '' ) ne 'monitor';
    die "Job $job->{id} is disabled - enable it before starting it\n"
      if !$job->{enabled};

    my @command = split ' ', ( $job->{command} // '' );
    die "Job $job->{id} has no command to run\n" if !@command;

    # ALREADY RUNNING IS A REFUSAL, not a second process. Without this, starting
    # a live monitor spawns a twin and overwrites the recorded pid, so the first
    # process keeps running with nothing on the board pointing at it - an orphan
    # monitor-dead cannot see, which is precisely the failure EPC-014 exists to
    # end. From a terminal that takes a deliberate mistake; with TKT-843's play
    # button it is one stray click, which is what made it worth fixing here.
    require Tira::Job;
    die "Job $job->{id} is already running as pid $job->{pid} - starting it "
      . "again would leave the first process with nothing on the board "
      . "pointing at it\n"
      if Tira::Job::job_monitor_alive( $job, _running_processes_for_jobs() );

    # A PIPELINE, NOT A REDIRECT. TKT-851, after his instruction that monitors
    # should not have separate logs and his answer to Q-112 choosing a feeder:
    # the monitor's output goes THROUGH a Tira command that records it against
    # this job, so the board hears from the monitor rather than reading its
    # leavings. That is what makes "when did this monitor last call in" a fact,
    # which is what TKT-873's silence rule needs.
    #
    # The shell owns the pipe, so the feeder lives and dies with the monitor
    # instead of being a second thing somebody has to start. And the feeder
    # drains continuously, which is the whole reason a pipe is safe here at all -
    # TKT-842 chose a file because a pipe with NO READER fills at about 64KB and
    # blocks the child forever. A pipe with a reader does not.
    #
    # THE FEEDER IS RESOLVED FROM THIS FILE, not from PATH. A monitor started by
    # a board that happens to have d2 on its PATH and one started by a board that
    # does not must behave the same, and the entrypoint sits at a known place
    # relative to this module - the same reasoning _view_dir uses for templates.
    require File::Basename;
    require File::Spec;
    my $feeder = File::Spec->catfile(
        File::Basename::dirname( File::Spec->rel2abs(__FILE__) ),
        File::Spec->updir, File::Spec->updir, File::Spec->updir,
        'skills', 'job', 'cli', 'feed' );

    # THE BOARD TRAVELS IN THE ENVIRONMENT, not on the command line. The feeder
    # has to find the same project this monitor belongs to, and a --project
    # argument would put the board's location into the process table for anyone
    # running ps. An inherited variable does not.
    my $root = $tira->discover_project( %{$args} );

    # THE COMMAND IS CHECKED BEFORE THE SHELL IS ASKED TO RUN IT. open3 used to
    # give this refusal for free: exec'ing a program that is not there failed,
    # and job.start said so. A shell ALWAYS starts, then fails inside itself with
    # exit 127 that nobody is waiting on - so a monitor whose command is
    # misspelled would look started, and only monitor-dead would notice, minutes
    # later and as an alarm rather than an answer. The check has to move here or
    # the refusal is lost with the redirect.
    die "$command[0]: command not found\n"
      if !_command_is_runnable( $command[0] );

    require IPC::Open3;

    # NOTHING OF THE JOB'S IS SHELL TEXT. The shell is here only to own the pipe;
    # the words it runs arrive as positional parameters, so a command holding a
    # semicolon or a backtick stays an argument - which is what open3(@command)
    # gave us before there was a pipeline, and what a stored, editable job record
    # has to keep. The only text sh parses is the fixed script on the next line.
    my $script = 'PERL="$1"; FEEDER="$2"; ID="$3"; shift 3; '
      . 'exec "$@" 2>&1 | exec "$PERL" "$FEEDER" --id "$ID"';

    my $pid = eval {
        local $ENV{TIRA_HOME} = $root;
        IPC::Open3::open3( my $in, my $out, my $err,
            'sh', '-c', $script, 'tira-monitor',
            $^X, $feeder, $job->{id}, @command );
    };
    if ( !$pid ) {
        my $why = $@ || 'could not be started';
        $why =~ s/\s+\z//;
        die "$command[0]: $why\n";
    }

    # SPAWNING AND RECORDING MUST NOT COME APART. The process exists the
    # instant open3 returns; the board only learns its pid on the next line.
    # If that write fails - a held lock, a full disk - the old code left a
    # RUNNING monitor that the board had no pid for, which monitor-dead then
    # reported dead on every pass while job.start, run again, started a second
    # copy. A live monitor reported dead is the noise that gets this rule
    # ignored, and a silent duplicate is worse.
    #
    # So the child is killed if it cannot be recorded, and the failure is
    # raised. Leaving nothing running is the state the caller can retry from.
    my $started = eval { $tira->job_started( %{$args}, id => $job->{id}, pid => $pid ) };
    if ( !$started ) {
        my $why = $@ || 'the start could not be recorded';
        $why =~ s/\s+\z//;
        kill 'TERM', $pid;
        waitpid $pid, 0;
        die "Started $job->{id} as pid $pid but could not record it, so it "
          . "was stopped again rather than left running unrecorded: $why\n";
    }
    return $started;
}

# The process table, asked for once and by the CLI layer, because the engine is
# forbidden every construct that could read it. Kept as its own sub so the
# start path can be tested without a real process table.
sub _running_processes_for_jobs {
    require Tira::CLI::Police;
    return Tira::CLI::Police::_running_processes();
}

# Run one job NOW, whatever its schedule says.
#
# His msg 6484: "each repeated job record has a play button. That the user can
# run them anytime bypass the schedule."
#
# ONE EXECUTOR. This is TKT-841's run_due_job with the due-check simply not
# asked - not a second implementation of running a command. That executor
# carries a deadlock fix (a pipe nobody drains blocks the child forever) and a
# signal-status fix (a killed job reported success) that only came out of
# review; a fresh executor written for a button would have carried neither.
#
# A MONITOR IS STARTED RATHER THAN FIRED, decided as TKT-843's CHK-001 before
# any of this was written. A monitor has no schedule to bypass - it is either up
# or it is not - so "run it now" on that row means start it, which is the action
# that answers the monitor-dead finding printed beside it.
sub run_now {
    my ( $tira, $args ) = @_;
    my $id = $args->{id} // '';
    my ($job) = grep { $_->{id} eq $id } @{ $tira->job_list( %{$args} ) };
    die "No job $id on this board\n" if !$job;

    return _start_monitor( $tira, $args, $job )
      if ( $job->{schedule_kind} // '' ) eq 'monitor';

    die "Job $job->{id} is disabled - enable it before running it\n"
      if !$job->{enabled};

    require Tira::CLI::Police;
    return Tira::CLI::Police::run_due_job( job => $job );
}

sub dispatch {
    my ( $tira, $args, $option, $command ) = @_;

    return $tira->job_list( %{$args} ) if $command eq 'job.list';

    # A monitor telling the board what it just said. TKT-851.
    #
    # READS AS INPUT ARRIVES. A feeder that collected and wrote at the end would
    # let the pipe fill at about 64KB and the monitor would block there forever -
    # the failure TKT-842 chose a file to avoid, reintroduced by the thing meant
    # to replace it. So this loops on readline and never waits for EOF to start.
    #
    # BATCHED, because one project lock per line would have a chatty poller
    # hammering the board. Lines go in when enough have gathered, and whatever is
    # left goes in when the input ends - so a monitor that says one thing an hour
    # is not held back waiting for a batch that never fills.
    if ( $command eq 'job.feed' ) {
        my $id = $args->{id} // '';
        die "A job id is required - which monitor is speaking?\n" if $id eq '';

        my @batch;
        my $flush = sub {
            return if !@batch;
            $tira->job_feed( %{$args}, id => $id, lines => [@batch] );
            @batch = ();
            return;
        };

        # A BATCH THAT NEVER FILLS MUST STILL GO IN, and the first version got
        # this wrong in a way only the container walkthrough showed. It flushed
        # at 25 lines or at end of input - and a monitor never ends, so a
        # poller printing a line a minute sat unheard for twenty-five minutes,
        # and one printing hourly for a day. The board read "never called in"
        # while the monitor was talking, which is the exact silence this epic
        # exists to end, rebuilt inside the fix for it. It would also have made
        # TKT-873's silence rule fire on monitors that were working.
        #
        # So the wait is bounded: block for at most this long, and if nothing
        # arrived, hand over whatever is held. A monitor is heard within seconds
        # of speaking however rarely it speaks, and a chatty one still batches.
        require IO::Select;
        my $watch = IO::Select->new();
        $watch->add( \*STDIN );

        while (1) {
            # can_read returns on timeout with nothing, which is the quiet this
            # is watching for - not an error and not end of input.
            if ( !$watch->can_read($QUIET_AFTER_SECONDS) ) {
                $flush->();
                next;
            }

            my $line = <STDIN>;
            last if !defined $line;    # the monitor's output really did end
            $line =~ s/\r?\n\z//;
            push @batch, $line;
            $flush->() if @batch >= $BATCH_LINES;
        }
        $flush->();
        return { id => $id, fed => 1 };
    }

    return run_now( $tira, $args ) if $command eq 'job.run';

    if ( $command eq 'job.start' ) {
        my ($job) = grep { $_->{id} eq ( $args->{id} // '' ) }
          @{ $tira->job_list( %{$args} ) };
        die "No job $args->{id} on this board\n" if !$job;
        return _start_monitor( $tira, $args, $job );
    }

    my $job_command = _command_of($option);

    return $tira->job_add(
        %{$args},
        schedule => $option->{schedule},
        ( defined $job_command ? ( command => $job_command ) : () ),
        ( defined $option->{message} ? ( message => $option->{message} ) : () ),
    ) if $command eq 'job.add';

    return $tira->job_update(
        %{$args},
        ( defined $option->{schedule} ? ( schedule => $option->{schedule} ) : () ),
        ( defined $job_command        ? ( command  => $job_command )        : () ),
        ( defined $option->{message}  ? ( message  => $option->{message} )  : () ),
        ( defined $option->{enabled} ? ( enabled => _enabled_of( $option->{enabled} ) ) : () ),
    ) if $command eq 'job.update';

    return $tira->job_delete( %{$args} ) if $command eq 'job.delete';

    # NOT a fallthrough. This used to be a bare `return $tira->job_delete(...)`
    # with no condition, safe only because the caller admits exactly four verbs
    # and the other three return above it - so the safety lived in a regex in
    # another file. TKT-841 and TKT-842 are both queued to add behaviour here,
    # and adding a verb to that regex without adding a branch here would have
    # DELETED the job instead of running it. A destructive default is the wrong
    # way round: the unknown case should refuse, and deleting should need to be
    # asked for by name.
    die "Tira::CLI::Job cannot dispatch '$command'\n";
}

1;

__END__

=head1 NAME

Tira::CLI::Job - the command bodies for repeated jobs

=head1 DESCRIPTION

C<tira.job.add>, C<list>, C<update> and C<delete>, lifted out of
C<Tira::CLI> so the index stays an index. Required at the point one of those
verbs runs, so a command that is not about jobs never compiles it.

What makes a schedule valid is decided in L<Tira::Job>, not here. This
module passes the arguments through and lets the engine's refusal reach the
caller unchanged, so the command line and the stored record cannot disagree.

=head1 STARTING A MONITOR

C<tira.job.start> is here rather than in the engine because starting one
means spawning a process, and the engine is forbidden every shell-invoking
construct. It records the pid through C<Tira::Job::job_started>, which is
what makes a later death detectable at all - without it the C<monitor-dead>
rule would guard a state nothing on the board could produce, and every
enabled monitor would read as dead on every pass.

Two decisions here are worth keeping. The spawn is C<IPC::Open3>, not a
hand-rolled C<fork>/C<setsid>/C<exec>: the child half of a hand-rolled detach
runs where C<Devel::Cover> cannot follow it, so the mandatory 100% statement
gate could only be met by writing code nobody runs, or by lowering the gate.
The honest cost is that the monitor is reparented rather than session-led, so
a terminal hangup still reaches it.

=head1 THE MONITOR IS STARTED INSIDE A PIPELINE

Its output no longer goes to a per-job file. C<tira.job.start> runs

    <the job's command> 2>&1 | tira.job.feed --id JOB-NNN

so everything the monitor prints is registered against the job that said it,
and C<last_output_at> records when it last called in - stamped once per
delivery rather than per line, so it answers "when did this monitor last
speak" and not "when was this line printed". TKT-851, from his instruction that monitors should
not have separate logs and his answer to Q-112: "each output will be registered
who talked to the police".

The earlier version wrote a file and had police follow it from a stored offset.
The file was chosen because a pipe with no reader fills at around 64KB and
blocks the writer forever - the deadlock TKT-841 was reviewed for - and a
monitor blocked on a full pipe is a stopped monitor that still looks started,
which is the failure this whole epic is about. That constraint has not gone
away; it is satisfied differently. B<The feeder is the reader.> It drains
continuously and lives inside the same pipeline as the monitor, so it cannot be
forgotten or started separately.

Three things about the spawn are easy to get wrong:

=over 4

=item * B<The command is checked before the shell is asked to run it.>
C<open3> gave that refusal for free by failing to exec a program that was not
there. A shell always starts and fails inside itself with an exit status nobody
is waiting on, so a misspelled command would look started until C<monitor-dead>
noticed minutes later - an alarm where there should have been an answer.

=item * B<Nothing of the job's is shell text.> The shell owns the pipe, but the
words it runs arrive as positional parameters, so a command holding a semicolon
or a backtick stays an argument. That is what C<open3(@command)> gave before
there was a pipeline, and a stored, editable job record has to keep it.

=item * B<The feeder is resolved from this file, not from PATH.> A monitor
started by a board that happens to have C<d2> on its PATH and one started by a
board that does not must behave the same - the reasoning C<_view_dir> already
uses for templates.

=back

The board's location travels to the feeder in the environment rather than as an
argument, so it does not appear in the process table for anyone running C<ps>.

=head1 THE FEEDER

C<tira.job.feed> reads standard input and records each line against the named
job. It is not a verb anybody types; C<job.start> builds the pipeline that uses
it.

It reads B<continuously> rather than collecting and writing at the end, which
is the whole reason the pipe is safe: a feeder that waited for EOF would be a
deadlock with extra steps, since the monitor it reads never finishes. Lines are
batched before they are written, because taking the project lock once per line
would have a chatty poller hammering the board, and whatever is left goes in
when the input goes quiet so a rare speaker is not held hostage to a batch that
never fills.

=cut
