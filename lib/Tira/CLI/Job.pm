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

# The monitor lifecycle lives in Tira::CLI::Job::Monitor - lifted there by his
# 500-line rule when TKT-920's work took this file from 496 lines to 583.
#
# THE OLD NAMES STAY AS FORWARDERS. A lift that renames what callers reach is
# indistinguishable from a regression to every test that walks lib/, and this
# board has had three of those from one lift. Nothing outside this file has to
# know the code moved.
sub _command_is_runnable {
    require Tira::CLI::Job::Monitor;
    return Tira::CLI::Job::Monitor::_command_is_runnable(@_);
}

sub _start_monitor {
    require Tira::CLI::Job::Monitor;
    return Tira::CLI::Job::Monitor::_start_monitor(@_);
}

sub _running_processes_for_jobs {
    require Tira::CLI::Job::Monitor;
    return Tira::CLI::Job::Monitor::_running_processes_for_jobs(@_);
}

sub _spawn_monitor {
    require Tira::CLI::Job::Monitor;
    return Tira::CLI::Job::Monitor::_spawn_monitor(@_);
}

sub _signal_monitor {
    require Tira::CLI::Job::Monitor;
    return Tira::CLI::Job::Monitor::_signal_monitor(@_);
}

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

        # WHICH MONITOR, ASKED BEFORE ANYTHING IS WATCHED. An empty id was
        # refused here and a NONEXISTENT one was not: the verb went straight to
        # the loop below, took the timeout branch, flushed an empty batch and
        # went round again - for ever, at two-second intervals, never touching
        # the job record and so never discovering the job was not there.
        #
        # THAT IS NOT A TIDINESS FIX. `tira.job.feed --id ID` is a documented
        # example and t/70-doc-examples.t runs every documented example
        # in-process, so the suite ran this against a job called "ID". It hangs
        # whenever prove hands that worker a standard input that stays open,
        # which is why it only bit sometimes - it cost two coverage gate runs,
        # twenty-one and twenty-nine minutes. TKT-928.
        #
        # A CRON JOB IS REFUSED TOO, for the reason job_started already refuses
        # to record a pid for one: a cron job is not up between runs, so nothing
        # is feeding on its behalf and a feed against one is a mistake somebody
        # wants told about rather than a wait.
        #
        # Once, before the loop. Inside it this would be a lookup per poll, and
        # the loop's shape is TKT-851's answer to a monitor that speaks rarely.
        my ($known) = grep { ( $_->{id} // '' ) eq $id }
          @{ $tira->job_list( %{$args} ) };
        die "Job '$id' is not on this board - which monitor is speaking?\n"
          if !$known;
        die "Job $id is a cron job, not a monitor - it runs when due, so "
          . "nothing feeds on its behalf\n"
          if ( $known->{schedule_kind} // '' ) ne 'monitor';

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
        ( defined $option->{expect_every}
            ? ( expect_every => $option->{expect_every} ) : () ),
        ( defined $option->{restart_every}
            ? ( restart_every => $option->{restart_every} ) : () ),
    ) if $command eq 'job.add';

    return $tira->job_update(
        %{$args},
        ( defined $option->{schedule} ? ( schedule => $option->{schedule} ) : () ),
        ( defined $job_command        ? ( command  => $job_command )        : () ),
        ( defined $option->{message}  ? ( message  => $option->{message} )  : () ),
        ( defined $option->{enabled} ? ( enabled => _enabled_of( $option->{enabled} ) ) : () ),

        # Passed only when named, so job_update's merge can tell "leave it
        # alone" from "clear it". An empty string is how a caller says the
        # monitor no longer declares one; _job_fields reads that as undef.
        ( defined $option->{expect_every}
            ? ( expect_every => $option->{expect_every} ) : () ),
        ( defined $option->{restart_every}
            ? ( restart_every => $option->{restart_every} ) : () ),
    ) if $command eq 'job.update';

    return $tira->job_delete( %{$args} ) if $command eq 'job.delete';

    # STOPPING IS TWO THINGS, and only one of them belongs to the engine. The
    # record is cleared there - Tira::Job cannot read a process table, and must
    # not, which is the boundary TKT-874 was fixed to respect. Signalling the
    # process is this layer's, because this layer is allowed to.
    #
    # The record is cleared FIRST and the signal follows. A signal that fails -
    # the process already gone, or owned by somebody else - must not leave the
    # board still pointing at a pid nobody is responsible for, which is the
    # whole fault TKT-869 is about. TKT-893.
    if ( $command eq 'job.stop' ) {
        my $stopped = $tira->job_stop( %{$args} );
        my $pid = $stopped->{stopped_pid};

        # THE WHOLE TREE, and how much of it there was. TKT-920: a monitor is
        # the shell that owns the pipe, the command and the feeder - four
        # processes when restart_every adds a loop - and TERM to the recorded
        # pid alone orphaned the rest to init while the record was cleared, so
        # the board forgot a monitor that was still running and the next
        # job.start's duplicate guard read that emptied record and began a
        # second one. Stop, start, stop, start is how JOB-006 came to be running
        # under two pids.
        #
        # The count is returned because a stop that signalled nothing and a stop
        # that signalled four looked identical from the board, which is what let
        # this go a day unseen.
        return { %{$stopped}, signalled => _signal_monitor($pid) };
    }

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

Since 5.45 the spawn and the signal that stops it live together in
L<Tira::CLI::Job::Monitor>, and the names here are forwarders. They were moved
because they have to agree about what the recorded pid B<is> and for one
release they did not: the spawn returned the pid of the shell owning the
pipeline and the stop signalled that pid alone, orphaning the command and the
feeder. The subs stayed forty lines and one sub apart in a file that had grown
to 583 lines, which is how the disagreement went unnoticed. TKT-920.

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

=head1 THE FEEDER REFUSES BEFORE IT READS

C<job.feed> resolves the job and refuses by name before standard input is
watched at all. Until 5.51 it refused an B<empty> id and accepted a
B<nonexistent> one: it went straight to the read loop, took the timeout branch,
flushed an empty batch and went round again - for ever, never touching the job
record and so never discovering the job was not there.

B<That mattered because the verb is a documented example.> F<t/70-doc-examples.t>
runs every documented example in-process, and C<tira.job.feed --id ID> is one -
so the suite ran it against a job called C<ID> and hung whenever C<prove> handed
that worker a standard input that stayed open. When prove had already closed the
write end, C<< <STDIN> >> returned undef and nothing looked wrong, which is why
it bit only sometimes and cost two coverage gate runs to find. TKT-928.

A cron job is refused for the reason L<Tira::Job>'s C<job_started> already
refuses to record a pid for one: it is not up between runs, so nothing is feeding
on its behalf.

The lookup happens B<once, before the loop>. Inside it, it would be a job-list
read every two seconds - and the loop's shape is TKT-851's answer to a monitor
that speaks rarely.

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
