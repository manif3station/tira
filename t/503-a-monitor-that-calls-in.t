#!/usr/bin/env perl
# A monitor that CALLS IN, rather than one whose leavings are read.
#
# TKT-851, after his answer to Q-112 on 2026-09-03: "To use the feeder command,
# each output will be registered who talked to the police."
#
# WHAT CHANGED AND WHY. The first implementation had the monitor write a spool
# and police follow it. That got output onto the bridge - which he confirmed was
# the right destination - but it kept the per-job log his original instruction
# said should not exist, and it made "this monitor is alive and working" an
# inference from a file's contents rather than a fact the monitor reported.
#
# The difference is not cosmetic. A spool nobody has written to and a monitor
# that has died look identical from outside. A monitor that has not CALLED IN
# for an hour is a fact about the monitor, and it is what his silence rule
# (TKT-873) needs to exist at all.
#
# THE DEADLOCK CONSTRAINT IS UNCHANGED and is why this is a pipeline rather than
# a library call: a pipe with no reader fills at about 64KB and blocks the child
# forever. The feeder is the reader, drains continuously, and lives inside the
# same pipeline as the monitor so it cannot be forgotten.
#
# WRITTEN RED. There is no feeder.
#
# WHAT THIS DOES NOT COVER: the silence rule itself (TKT-873, its own card and
# its own six declared surfaces), and the browser, which he keeps.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;

require Tira::Job;

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

# The real clock, for the same reason t/500 needs one: last_output_at is
# compared against wall time by the rule that reads it, and a fixed clock makes
# a monitor that just spoke look like one that spoke in another era.
my $tira = Tira->new;
$tira->project_new(
    name => 'CalledIn', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'CIS', epic_prefix => 'CIE', ticket_prefix => 'CIT',
);

my $monitor = $tira->job_add(
    project => $root, schedule => 'monitor',
    command => 'tira-monitor-under-test --poll',
);
is( $monitor->{schedule_kind}, 'monitor', 'a monitor to feed from' );

# --- the engine can be told what a monitor said ------------------------------

ok( Tira::Job->can('job_feed'),
    'the engine has a way to be told what a monitor said' );

# --- and it records it, registered against the job that said it --------------

{
    $tira->job_feed( project => $root, id => $monitor->{id},
        lines => [ 'hunt found nothing this hour', 'next sweep at 06:00' ] );

    my ($record) = grep { $_->{id} eq $monitor->{id} }
      @{ $tira->job_list( project => $root ) };

    ok( $record->{last_output_at},
        'the job records WHEN it last called in - which is the fact a silence '
          . 'rule needs and a spool cannot give' );

    my $said = join ' ', @{ $record->{output} || [] };

    # non-empty is the whole claim: the assertions below ask what the record
    # contains, and an empty one would fail them for the wrong reason.
    like( $said, qr/\S/, 'and what it said is on the record' );
    like( $said, qr/hunt found nothing this hour/, 'both lines of it' );
    like( $said, qr/next sweep at 06:00/, 'in the order it said them' );
}

# --- police drains it, and it is not said twice ------------------------------
#
# The same discipline the spool version had, and the reason is unchanged: a rule
# that repeats every pass makes the bridge unreadable, which fails in the same
# direction as the silence it is fixing.

{
    my ( $lines, $dropped ) = Tira::Job::job_output_drain( $tira,
        project => $root, id => $monitor->{id} );
    is( scalar @{$lines}, 2, 'police takes what has accumulated' );
    is( $dropped, 0, 'and nothing was dropped for two lines' );

    my ( $again ) = Tira::Job::job_output_drain( $tira,
        project => $root, id => $monitor->{id} );
    is( scalar @{$again}, 0,
        'and a second drain finds nothing - what was taken is gone' );
}

# --- a monitor that has said nothing has still said nothing ------------------

{
    my ($record) = grep { $_->{id} eq $monitor->{id} }
      @{ $tira->job_list( project => $root ) };
    my $stamp = $record->{last_output_at};

    Tira::Job::job_output_drain( $tira, project => $root, id => $monitor->{id} );

    my ($after) = grep { $_->{id} eq $monitor->{id} }
      @{ $tira->job_list( project => $root ) };
    is( $after->{last_output_at}, $stamp,
        'draining nothing does not move the last-called-in time - a monitor '
          . 'that has not spoken must not look like one that has' );
}

# --- a chatty monitor cannot fill the board ----------------------------------
#
# The cap moved. On the spool it bounded what one PASS announced; here it also
# has to bound what the record HOLDS, because the feeder writes and police may
# not read for thirty seconds.

{
    $tira->job_feed( project => $root, id => $monitor->{id},
        lines => [ map {"line $_ of a very chatty poller"} 1 .. 500 ] );

    my ($record) = grep { $_->{id} eq $monitor->{id} }
      @{ $tira->job_list( project => $root ) };
    cmp_ok( scalar @{ $record->{output} || [] }, '<', 500,
        'the record does not grow without bound between passes' );

    my ( $lines, $dropped ) = Tira::Job::job_output_drain( $tira,
        project => $root, id => $monitor->{id} );
    cmp_ok( $dropped, '>', 0,
        'and what it could not keep is COUNTED, not silently forgotten' );

    my $said = join ' ', @{$lines};
    like( $said, qr/line 500 of a very chatty poller/,
        'the lines kept are the newest, which is what a monitor is for' );
}

# --- the feeder command exists and is the drainer ----------------------------
#
# Asserted on the entrypoint rather than by running a pipeline: the shape that
# matters is that a command exists for a monitor's output to be fed THROUGH,
# which is what makes the registration possible and what he asked for.

{
    my $entrypoint = 'skills/job/cli/feed';
    ok( -f $entrypoint, 'there is a command a monitor feeds its output through' );
    ok( -x $entrypoint, 'and it is executable, like every other entrypoint' );

    # The BEHAVIOUR is asserted against the handler, not the entrypoint. Every
    # Tira entrypoint is a thin shim that forwards to Tira::CLI - the first
    # version of this assertion read the shim and failed, which was the test
    # being wrong about where the code lives rather than the code being wrong.
        my $body = Suite::cli_source();

    # THE READER MOVED ON TKT-927 and this reads it where it is now. The
    # job.feed branch used to hold the loop; the feeder that owns its own pipe
    # would have been a second copy of it, so both call one sub. The claims
    # below are unchanged - they were never about which branch the loop sat in.
    my ($feeder) = $body =~ /(sub \s feed_from_handle .*? \n \} )/xs;

    # non-empty is the whole claim: the assertions below ask what the feeder
    # does, and an unmatched block would let them pass against nothing.
    like( $feeder // '', qr/\S/, 'the handler has a job.feed body to check' );

    # It must READ CONTINUOUSLY. A feeder that collected and wrote at the end
    # would be a deadlock with extra steps - the monitor fills the pipe at about
    # 64KB and stops, which is the failure TKT-842 chose a file to avoid.
    like( $feeder, qr/<\$handle>/,
        'that reads its input as it arrives rather than collecting it - from a '
          . 'handle now rather than from STDIN by name, because the same loop '
          . 'serves the verb somebody pipes into and the feeder that owns its '
          . 'own pipe' );

    # And the WAIT MUST BE BOUNDED. Reading line by line is not enough on its
    # own: a blocking read with a batch that only empties at 25 lines or EOF
    # left a once-an-hour monitor unheard for a day, which the walkthrough
    # found after the suite and the coverage gate were both green. Asserted on
    # the source because it is a property of how long the feeder will WAIT, and
    # the behaviour itself is proven against a real pipe further down.
    like( $feeder, qr/can_read\s*\(\s*\$quiet/,
        'and gives up waiting after a bounded quiet, so a batch that will not '
          . 'fill does not hold a rare speaker for ever' );

    # And it must not hold a rare speaker hostage to a batch that never fills.
    like( $feeder, qr/\$flush->\(\);\s*\z|\$flush->\(\);/,
        'flushing whatever is left when the input ends' );
}

# --- and the feeder is actually RUN, not only read --------------------------
#
# The assertions above read the handler's source, which is the only way to state
# "it does not wait for EOF" - a property about WHEN it acts that no return value
# reveals. But source-reading covers no statements, and the coverage gate caught
# that honestly: the read loop and the flush inside it were the three uncovered
# statements in this module. So the handler is also driven for real, from a
# STDIN it can actually read.

{
    require Tira::CLI::Job;

    my $driven = $tira->job_add(
        project => $root, schedule => 'monitor',
        command => 'tira-monitor-driven-for-real --poll',
    );

    # THROUGH A REAL PIPE, not an in-memory string filehandle. The first version
    # of this used one, and it wedged the suite the moment the feeder started
    # waiting on IO::Select: a string handle has no underlying file descriptor,
    # so select() has nothing to watch. Production is always a pipe - it is the
    # other half of the monitor's pipeline - so the test that stands in for it
    # has to be one too. A fixture that cannot represent the real input is a
    # fixture that will disagree with production eventually.
    #
    # More than one batch's worth, so the mid-stream flush runs as well as the
    # one at the end. A single short feed would leave the batching untested and
    # still look green.
    pipe( my $read, my $write ) or die "cannot make a pipe: $!";
    my $talker = fork();
    die "cannot fork: $!" if !defined $talker;
    if ( !$talker ) {
        close $read;
        print {$write} "chatty line $_\n" for 1 .. 60;
        close $write;    # EOF: this monitor's output really did end
        exit 0;
    }
    close $write;

    {
        local *STDIN;
        open STDIN, '<&', $read or die "cannot hand the feeder the pipe: $!";
        local $SIG{ALRM} = sub { die "the feeder never returned\n" };
        alarm 30;
        my $answer = eval {
            Tira::CLI::Job::dispatch( $tira,
                { project => $root, id => $driven->{id} }, {}, 'job.feed' );
        };
        alarm 0;
        close STDIN;
        is( $answer->{fed}, 1, 'the feeder reports it fed what it was given' );
        is( $answer->{id}, $driven->{id}, 'against the job that was speaking' );
    }
    waitpid $talker, 0;
    close $read;

    my ($record) = grep { $_->{id} eq $driven->{id} }
      @{ $tira->job_list( project => $root ) };
    my $held = join ' ', @{ $record->{output} || [] };

    # non-empty is the whole claim: the assertions below ask what the record
    # holds, and an empty one would fail them for the wrong reason.
    like( $held, qr/\S/, 'and the board heard it' );
    like( $held, qr/chatty line 60/,
        'including the last line, which is what the end-of-input flush is for' );
    ok( $record->{last_output_at},
        'and the run stamped when it called in' );

    # The newline is the feeder's frame, not part of what was said. A line
    # arriving with its terminator still attached would put a blank into the
    # middle of a bridge message.
    unlike( $held, qr/\n/,
        'with the line endings stripped rather than carried into the record' );
}

# --- a monitor that speaks RARELY is still heard ------------------------------
#
# THE BUG THIS GUARDS AGAINST WAS MINE, and only the container walkthrough found
# it. The feeder flushed at 25 lines or at end of input. A monitor never ends -
# that is what makes it a monitor - so a poller printing a line a minute sat
# unheard for twenty-five minutes and an hourly one for a day, while the board
# read "never called in". That is the silence this epic exists to end, rebuilt
# inside the fix for it, and it would have made TKT-873's rule fire on monitors
# that were working perfectly.
#
# Asserted through a PIPE rather than a string, because a string filehandle is
# always ready to read and would never exercise the quiet path at all - it would
# pass on the shape of the thing rather than the behaviour.

{
    require Tira::CLI::Job;

    my $rare = $tira->job_add(
        project => $root, schedule => 'monitor',
        command => 'tira-monitor-that-speaks-once --poll',
    );

    pipe( my $read, my $write ) or die "cannot make a pipe: $!";

    my $child = fork();
    die "cannot fork: $!" if !defined $child;
    if ( !$child ) {
        close $read;
        $write->autoflush(1);

        # ONE line, then hold the pipe open and say nothing - a monitor that has
        # spoken and is now waiting for its next poll. Far fewer than the batch,
        # and no EOF, so only an idle flush can get this onto the board.
        print {$write} "the one thing I have to say this hour\n";
        sleep 6;
        close $write;
        exit 0;
    }

    close $write;

    my $held;
    {
        local *STDIN;
        open STDIN, '<&', $read or die "cannot hand the feeder the pipe: $!";

        # Read in a child of our own so a hang here fails the test rather than
        # wedging the suite: the parent waits, and gives up if it must.
        local $SIG{ALRM} = sub { die "the feeder never returned\n" };
        alarm 30;
        eval {
            Tira::CLI::Job::dispatch( $tira,
                { project => $root, id => $rare->{id} }, {}, 'job.feed' );
            1;
        };
        alarm 0;
        close STDIN;
    }
    waitpid $child, 0;
    close $read;

    my ($record) = grep { $_->{id} eq $rare->{id} }
      @{ $tira->job_list( project => $root ) };
    $held = join ' ', @{ $record->{output} || [] };

    like( $held, qr/the one thing I have to say this hour/,
        'a monitor that said one thing and went quiet was heard anyway - a '
          . 'batch that will not fill must not hold its output for ever' );
    ok( $record->{last_output_at},
        'and the board records that it called in, which is what a silence rule '
          . 'reads and what a held batch would have made a lie' );
}

# --- a spawn that fails for a reason the pre-check cannot see ----------------
#
# _start_monitor now checks the command is runnable BEFORE building the
# pipeline, because a shell always starts and would have swallowed that refusal.
# That check made the open3 failure branch unreachable from any command a test
# can name - the coverage gate said so, three uncovered statements - but it is
# not dead code: fork can fail, and sh itself can be missing. So the failure is
# induced rather than the branch deleted, which is the difference between
# proving a refusal works and removing the evidence that it exists.

{
    require Tira::CLI::Job;
    require IPC::Open3;

    my $spawnable = $tira->job_add(
        project => $root, schedule => 'monitor',
        command => $^X . ' -e 1',
    );

    my $refused = do {
        no warnings 'redefine';
        local *IPC::Open3::open3 = sub { die "fork: Resource temporarily unavailable\n" };
        !eval {
            Tira::CLI::Job::dispatch( $tira,
                { project => $root, id => $spawnable->{id} }, {}, 'job.start' );
            1;
        };
    };
    my $why = $@;

    ok( $refused, 'a monitor whose spawn fails is refused rather than recorded' );
    like( $why, qr/\Q$^X\E/,
        'naming the command that could not be started, since the pipeline is '
          . 'not somewhere a person can read the failure off' );
    like( $why, qr/Resource temporarily unavailable/,
        'and carrying the reason the system gave, rather than a generic one' );

    my ($record) = grep { $_->{id} eq $spawnable->{id} }
      @{ $tira->job_list( project => $root ) };
    ok( !defined $record->{pid},
        'and no pid was recorded for a process that does not exist - a board '
          . 'pointing at a pid nobody started is what monitor-dead then cries about' );
}

# --- a drain that fails is REPORTED, not swallowed ---------------------------
#
# Police drains after the bridge write. If that write-back fails silently the
# same lines arrive again next pass, and a bridge repeating itself is the noise
# this rule was careful to avoid - so the failure has to reach somebody.

{
    require Tira::CLI::Police;

    my $noisy = $tira->job_add(
        project => $root, schedule => 'monitor',
        command => 'tira-monitor-that-cannot-be-drained --poll',
    );

    my $complaint = '';
    {
        no warnings 'redefine';
        local *Tira::Job::job_output_drain = sub { die "the jobs record is locked\n" };
        open my $capture, '>', \$complaint or die $!;
        my $old = select $capture;
        local *STDERR = $capture;
        # THE VIOLATION HAS TO BE HERE, and it was not until TKT-925. The drain
        # used to fire on the mark alone, so a monitor's words came off the
        # record even when the pass had reported nothing about it - a suspended
        # rule, a declined finding - and nobody had seen them. It now asks
        # whether the pass actually produced a finding for this monitor, so a
        # fixture that hands it a mark and no violation is a fixture describing
        # a state the code no longer reaches.
        #
        # The sub_key is how the two are matched, and the rule builds it as
        # "JOB-ID:what was said" - so it is written that way here rather than
        # invented.
        Tira::CLI::Police::advance_monitor_output(
            $tira, { project => $root },
            { monitor_output =>
                  [ { id => $noisy->{id}, count => 3, dropped => 0, spoke => 1 } ],
              violations => [
                  { rule => 'monitor-output', policy => 'POL-001',
                    ref => '', action => 'bridge-reminder',
                    sub_key => "$noisy->{id}:it said something",
                    detail => "$noisy->{id} said: it said something" } ] } );
        select $old;
        close $capture;
    }

    # non-empty is the whole claim: the assertions below ask what the complaint
    # says, and an empty one would satisfy a "does not crash" reading while
    # proving the opposite of what this is for.
    like( $complaint, qr/\S/, 'a drain that failed said so' );
    like( $complaint, qr/\Q$noisy->{id}\E/, 'naming the monitor it could not drain' );
    like( $complaint, qr/announced again/,
        'and saying what the consequence is, which is what makes it worth printing' );
}

# --- a feeder with no job named is refused -----------------------------------

{
    require Tira::CLI::Job;
    ok( !eval {
            Tira::CLI::Job::dispatch( $tira, { project => $root }, {}, 'job.feed' );
            1;
        },
        'a feeder that was not told which monitor is speaking is refused' );
    like( $@, qr/job id is required/i,
        'saying what was missing, since the pipeline that built it is not '
          . 'somewhere a person can read the mistake off' );
}

done_testing();

__END__

=head1 NAME

503-a-monitor-that-calls-in.t - the feeder, and output registered to its job

=head1 WHY

TKT-851, his Q-112 answer: "each output will be registered who talked to the
police". Following a spool tells police what was said; a feeder tells it that
this monitor said it, now - which is the fact TKT-873's silence rule needs and
which a file cannot provide.

=head1 THE DEADLOCK CONSTRAINT IS WHY THIS IS A PIPELINE

A pipe with no reader fills at about 64KB and blocks the monitor forever. The
feeder is the reader and drains continuously, inside the same pipeline as the
monitor so it cannot be forgotten or started separately.

=head1 THE CAP MOVED

On the spool it bounded what one pass announced. Here it also bounds what the
record HOLDS: the feeder writes continuously and police may not read for thirty
seconds, so the buffer needs its own limit - and what it drops is counted rather
than forgotten.

=cut
