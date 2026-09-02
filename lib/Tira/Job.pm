package Tira::Job;

# Repeated jobs: a schedule the board owns, rather than a loop a session owns.
#
# WHY THIS EXISTS, and it is worth keeping because the failure was quiet.
# Three standing hunts - hourly bugs, two-hourly improvements, three-hourly
# doc-gaps - ran as in-session monitors. On 2026-09-02 all three had been
# dead for hours and nobody noticed, because a loop that has stopped and a
# loop with nothing to report produce identical output: none. Michael asked
# "The bug hunting and improvement hunting and doc-gap hunting loops all
# stoped?" and the answer was yes. The agent had no way to tell.
#
# A schedule on the board is visible, survives any session, and is policed
# like every other record. EPC-014, TKT-836.
#
# THE CENTRAL RULE IS THE REFUSAL. A malformed schedule is rejected when it
# is written, naming what was wrong, and nothing is stored. Storing it would
# rebuild the same ambiguity one layer down: a job that never fires because
# its cron is nonsense is indistinguishable from a job with nothing to
# announce, and the board would be claiming a schedule it does not have.
#
# TWO OUTPUT MODES, his msg 6487: "either set to run a command and output to
# the police bridge or direct message to the bridge". A job carries a command
# OR a message, never both and never neither, and which one it is is stored
# explicitly rather than inferred from which field is populated - a caller
# reading the record should not have to guess.
#
# TWO SCHEDULE KINDS, same message: a crontab string, or the literal
# 'monitor' for a long-running poller. schedule_kind records which, so no
# caller re-parses the schedule to find out.
#
# IN ITS OWN MODULE FROM THE START. TKT-746 is decomposing lib/Tira.pm - three
# concerns lifted so far, 15,264 lines down to 14,177 - so new code goes
# beside those rather than into the file they are being pulled out of. Tira
# keeps thin forwarders that require this lazily, the same shape Tira::Toon,
# Tira::Tasklist and Tira::Render already use.

use strict;
use warnings;

use File::Path ();
use File::Spec;
use POSIX ();
use Time::Local ();

sub _job_path {
    my ( $self, $root ) = @_;
    return File::Spec->catfile( $root, '.tira', 'jobs.json' );
}

sub _job_read {
    my ( $self, $root ) = @_;
    my $path = _job_path( $self, $root );
    return [] if !-f $path;
    open my $fh, '<:raw', $path or die "Cannot read jobs '$path': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh or die "Cannot close jobs '$path': $!\n";
    return Tira::json_object()->utf8->decode($content);
}

# The five cron fields, each with the range it is allowed to name. Held as
# data rather than as five hand-written checks so a refusal can say which
# field was wrong and what its range is, which is the difference between "bad
# schedule" and something a person can act on.
my @CRON_FIELDS = (
    { name => 'minute',       min => 0, max => 59 },
    { name => 'hour',         min => 0, max => 23 },
    { name => 'day of month', min => 1, max => 31 },
    { name => 'month',        min => 1, max => 12 },
    { name => 'day of week',  min => 0, max => 7 },
);

# One field of one expression, expanded to the set of values it matches.
# Returns nothing when the field is malformed, and the caller turns that into
# a refusal naming the field - so every rejection can say where it was.
sub _cron_field_values {
    my ( $spec, $field ) = @_;
    my %hit;
    for my $part ( split /,/, $spec, -1 ) {
        return if $part eq '';

        my $step = 1;
        if ( $part =~ s{/(\d+)\z}{} ) {
            $step = $1;
            return if $step == 0;
        }

        my ( $from, $to );
        if ( $part eq '*' ) {
            ( $from, $to ) = ( $field->{min}, $field->{max} );
        }
        elsif ( $part =~ /\A(\d+)-(\d+)\z/ ) {
            ( $from, $to ) = ( $1, $2 );
        }
        elsif ( $part =~ /\A(\d+)\z/ ) {
            ( $from, $to ) = ( $1, $1 );

            # A bare number with a step means "from here to the end", the
            # way cron reads 5/10. Without this, '0/2' matched only 0.
            $to = $field->{max} if $step > 1;
        }
        else {
            return;
        }

        return if $from < $field->{min} || $to > $field->{max} || $from > $to;
        for ( my $v = $from; $v <= $to; $v += $step ) { $hit{$v} = 1 }
    }
    return \%hit;
}

# Parses a crontab expression into five value-sets, or dies naming the field
# and its range. Dying rather than returning false is deliberate: every
# caller of this wants the reason, and the one place that does not (the
# due-check, reading an already-stored schedule) has already been past this
# on the way in.
sub _cron_parse {
    my ($schedule) = @_;
    die "A schedule is required\n" if !defined $schedule || $schedule eq '';

    my @parts = split ' ', $schedule;
    die "A cron schedule has five fields (minute hour day month weekday), not "
      . scalar(@parts) . " - got '$schedule'\n"
      if @parts != 5;

    my @sets;
    for my $i ( 0 .. 4 ) {
        my $values = _cron_field_values( $parts[$i], $CRON_FIELDS[$i] );
        die "The $CRON_FIELDS[$i]{name} field '$parts[$i]' is not valid - it takes "
          . "$CRON_FIELDS[$i]{min} to $CRON_FIELDS[$i]{max}\n"
          if !$values;
        push @sets, $values;
    }
    return \@sets;
}

# Why a schedule would be refused, as a string, or undef when it is fine.
#
# THE SAME VALIDATOR THE WRITE PATH USES, which is the whole point. The editor
# modal has to tell somebody their crontab is wrong while they type, and the
# obvious way to do that is a regex in JavaScript - which is how the engine and
# the browser ended up disagreeing about attachment content types (TKT-713).
# Two validators for one format do not stay equal; they drift, and the drift is
# only discovered when a value the browser accepted is refused on save.
#
# So this asks _cron_parse and reports what it said. It does not decide
# anything itself, which means it cannot disagree with the write path however
# the rules change later. EPC-014, TKT-843.
sub schedule_refusal {
    my ($schedule) = @_;
    return 'A schedule is required - a cron expression, or \'monitor\''
      if !defined $schedule || $schedule eq '';
    return undef if $schedule eq 'monitor';

    local $@;
    return undef if eval { _cron_parse($schedule); 1 };
    my $why = $@ || 'That schedule cannot be read';
    $why =~ s/\s+\z//;
    return $why;
}

sub _job_next_id {
    my ( $root, $jobs ) = @_;
    my $max = 0;
    for my $job ( @{$jobs} ) {
        my ($number) = ( $job->{id} // '' ) =~ /(\d+)\z/;
        $max = $number if defined $number && $number > $max;
    }
    return sprintf( 'JOB-%03d', $max + 1 );
}

# Validates the schedule and the mode together, because they are the two
# things a caller can get wrong and both refusals want to happen before
# anything is written.
sub _job_fields {
    my (%args) = @_;

    my $schedule = $args{schedule};
    die "A schedule is required - a cron expression, or 'monitor'\n"
      if !defined $schedule || $schedule eq '';

    my $kind = $schedule eq 'monitor' ? 'monitor' : 'cron';
    _cron_parse($schedule) if $kind eq 'cron';

    my $has_command = defined $args{command} && $args{command} ne '';
    my $has_message = defined $args{message} && $args{message} ne '';
    die "A job needs either a command to run or a message to announce\n"
      if !$has_command && !$has_message;
    die "A job takes either a command or a message, not both - "
      . "a record carrying both cannot say which the bridge should get\n"
      if $has_command && $has_message;

    # A monitor announces nothing, so a monitor with only a message is a
    # record with no reachable behaviour at all: it is never "due", so job-due
    # never speaks for it; job.start refuses it for having nothing to run; and
    # the liveness check has no command to look for in the process table. It
    # would sit there being reported dead forever by monitor-dead, which turns
    # a rule written to end a silence into one that cries every pass about a
    # record nobody can fix except by deleting it.
    #
    # Refused at the point of writing, like every other malformed job here.
    # Storing it would rebuild the same ambiguity one layer down, which is the
    # thing this file exists to refuse.
    die "A 'monitor' job runs a command - give --command, not --message. "
      . "A monitor stays running rather than firing on a tick, so there is "
      . "nothing for it to announce\n"
      if $kind eq 'monitor' && $has_message;

    return (
        schedule      => $schedule,
        schedule_kind => $kind,
        mode          => $has_command ? 'command' : 'message',
        command       => $has_command ? $args{command} : undef,
        message       => $has_message ? $args{message} : undef,
    );
}

sub job_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my %fields = _job_fields(%args);
    return $self->_with_project_lock( $root, sub {
        my $jobs = _job_read( $self, $root );
        my $now  = $self->{clock}->();
        my $job  = {
            id => _job_next_id( $root, $jobs ), %fields,
            enabled => 1, last_run => undef,
            created_at => $now, last_updated => $now,
        };
        push @{$jobs}, $job;
        $self->_write_json( _job_path( $self, $root ), $jobs );
        return $job;
    } );
}

sub job_list {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return _job_read( $self, $root );
}

sub _job_find {
    my ( $jobs, $id ) = @_;
    my ($job) = grep { $_->{id} eq ( $id // '' ) } @{$jobs};
    die "No job '$id'\n" if !$job;
    return $job;
}

sub job_update {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "A job id is required\n" if !defined $args{id} || $args{id} eq '';

    return $self->_with_project_lock( $root, sub {
        my $jobs = _job_read( $self, $root );
        my $job  = _job_find( $jobs, $args{id} );

        # Validated against the job as it WOULD be, not against the arguments
        # alone - otherwise changing only the schedule of a command-mode job
        # would be refused for having no command, and changing only the
        # message would silently leave a stale command behind it.
        my %merged = (
            schedule => $args{schedule} // $job->{schedule},
            ( defined $args{command} ? ( command => $args{command} )
              : defined $args{message} ? ( message => $args{message} )
              : $job->{mode} eq 'command' ? ( command => $job->{command} )
              : ( message => $job->{message} ) ),
        );
        my %fields = _job_fields(%merged);

        %{$job} = ( %{$job}, %fields );
        $job->{enabled} = $args{enabled} ? 1 : 0 if defined $args{enabled};
        $job->{last_updated} = $self->{clock}->();
        $self->_write_json( _job_path( $self, $root ), $jobs );
        return $job;
    } );
}

# Where a monitor's output goes. Beside the jobs file, named for the job, so
# that finding it needs no lookup and deleting the board takes it with it.
#
# The engine owns the PATH and the CLI owns the writing, for the same reason
# the liveness check is split that way: the engine may not open a process, but
# it is the only thing that knows where this board keeps its records.
sub job_log_path {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "A job id is required\n" if !defined $args{id} || $args{id} eq '';

    my $directory = File::Spec->catdir( $root, '.tira', 'jobs' );
    File::Path::make_path($directory) if !-d $directory;

    # The id is generated by _job_next_id and is JOB-NNN, but a path is built
    # from it and a board file is not a place to find out that an id could
    # contain a slash. Refused rather than sanitised: quietly rewriting an id
    # would make the log for JOB-1/x and JOB-1-x the same file.
    die "Job id '$args{id}' cannot be used as a file name\n"
      if $args{id} =~ m{[/\\]} || $args{id} eq '.' || $args{id} eq '..';

    return File::Spec->catfile( $directory, "$args{id}.log" );
}

# A monitor has started, and this is the pid it started as. Recorded through
# the engine rather than written into the file by whoever spawned it, so that
# there is one path to the fact and one place it can be wrong.
#
# Refused for a cron-kind job. A cron job is not supposed to be up between
# runs, so a pid on one would be a fact about a process that has already
# exited - and job_monitor_alive would then have to decide which pids it is
# allowed to believe. Refusing the write keeps that question from existing.
sub job_started {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "A job id is required\n" if !defined $args{id} || $args{id} eq '';
    die "A pid is required - job_started records what a monitor started as\n"
      if !defined $args{pid} || $args{pid} !~ /\A[1-9][0-9]*\z/;

    return $self->_with_project_lock( $root, sub {
        my $jobs = _job_read( $self, $root );
        my $job  = _job_find( $jobs, $args{id} );
        die "Job $args{id} is a cron job, not a monitor - only a monitor runs "
          . "continuously and has a pid to record\n"
          if ( $job->{schedule_kind} // '' ) ne 'monitor';

        $job->{pid}          = $args{pid} + 0;
        $job->{started_at}   = $self->{clock}->();
        $job->{last_updated} = $job->{started_at};
        $self->_write_json( _job_path( $self, $root ), $jobs );
        return $job;
    } );
}

# The wall-clock seconds in a stamp, or undef if it does not carry one.
#
# Both stamps this compares are LOCAL time: job records come from Tira::_now,
# which formats localtime and appends the local offset, and a process time
# comes from `ps lstart`, which is local and carries no offset at all. So the
# offset is deliberately ignored rather than parsed - the two are already in
# the same zone, and the only thing asked of the result is the difference
# between them.
sub _stamp_seconds {
    my ($text) = @_;
    return undef if !defined $text;
    my ( $y, $mo, $d, $h, $mi, $sec ) =
      $text =~ /\A(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/
      or return undef;
    return Time::Local::timegm_modern( $sec, $mi, $h, $d, $mo - 1, $y );
}

# Is this monitor actually running? Takes the process table as data - the
# engine never reads it, because t/106 forbids qx, system, exec and piped open
# anywhere outside lib/Tira/CLI, and the table needs ps or tasklist. The CLI
# gathers it (Tira::CLI::Police::_running_processes) and this decides.
#
# A PID IS NOT ENOUGH ON ITS OWN, and this is the whole design decision of
# TKT-842 rather than an implementation detail. The board's own precedent,
# police_claim_singleton, asks `kill 0, $pid` and believes the answer. That is
# fine for a singleton claimed seconds ago; it is not fine here, because pids
# are reused, and a reused pid answers `kill 0` in the affirmative. A dead
# monitor reported as alive is exactly the silent death this card exists to
# prevent, so the pid narrows the search and the COMMAND confirms it.
#
# What this does NOT detect, stated so nobody reads more into it than it says:
# a monitor that is alive but wedged - process up, polling stopped - is alive
# by this measure. Catching that needs the monitor to report progress, which
# is a heartbeat, which needs the monitored thing to cooperate; every monitor
# EPC-014 is meant to absorb is an existing command that will never write one.
sub job_monitor_alive {
    my ( $job, $processes ) = @_;
    return 0 if !$job || ( $job->{schedule_kind} // '' ) ne 'monitor';

    # Never started, or started and the pid cleared. Not running, and saying
    # so is the point - an enabled monitor with no pid is the commonest way
    # for one to be missing after a machine restart.
    my $pid = $job->{pid};
    return 0 if !defined $pid || $pid eq '';

    # The COMMAND only. A message is not something a process can be running,
    # and falling back to one would have matched a monitor's announcement
    # text against a command line - meaningless, and true only by accident.
    # _job_fields now refuses a message-mode monitor outright; this stays
    # correct for a record written before it did.
    my $wanted = $job->{command} // '';
    return 0 if !length $wanted;

    for my $process ( @{ $processes || [] } ) {
        next if ( $process->{pid} // '' ) ne "$pid";
        my $seen = $process->{command} // '';

        # WHEN BOTH START TIMES ARE KNOWN THEY SETTLE IT BY THEMSELVES, and
        # the command is not consulted at all. The board records the moment it
        # spawned the monitor; the process at that pid either started then or
        # it is something else wearing a recycled pid. That is a fact about
        # identity, where a command comparison is only a resemblance.
        #
        # THIS ORDER IS THE FIX FOR TKT-860, and the bug it closes was live in
        # production. Comparing commands FIRST reported a running monitor as
        # dead whenever the command was a wrapper: `d2 is-agent-sleeping` execs
        # perl with the resolved path, so the stored string never appears in
        # the child's argv and containment failed. Nearly every command on this
        # board begins with d2, so the rule written to end a silence cried on
        # every pass instead. The earlier comment here claimed containment
        # coped with "the interpreter, the absolute path and whatever the shell
        # expanded" - true when the stored command is the program that ends up
        # running, false for a wrapper, whose own name is gone after exec.
        #
        # The window is symmetric and a minute wide. Later means a reused pid.
        # EARLIER means it cannot be ours either - a process that began before
        # we spawned ours cannot have been given our pid while it was still
        # alive - so both directions are rejected rather than only the one that
        # was obvious first.
        my $recorded = _stamp_seconds( $job->{started_at} );
        my $running  = _stamp_seconds( $process->{started_at} );
        if ( defined $recorded && defined $running ) {
            my $apart = $running - $recorded;
            $apart = -$apart if $apart < 0;
            return $apart <= 60 ? 1 : 0;
        }

        # NO START TIME TO COMPARE, so the command is what is left. Windows is
        # the case that matters: tasklist reports a program name and no start
        # time at all. A record written before starts were recorded lands here
        # too, and keeps working rather than reading dead for ever.
        #
        # index rather than equality: ps reports the command as the kernel has
        # it, which carries the interpreter and absolute paths the stored
        # command need not repeat - which is true here, where the stored
        # command IS the program, and was never true for a wrapper.
        return 1 if index( $seen, $wanted ) >= 0;

        # WINDOWS CANNOT ANSWER THE FULL QUESTION, so it is asked a smaller
        # one rather than a wrong one. `tasklist /fo csv /nh` reports the
        # process NAME - "perl.exe" - and no command line at all, so the match
        # above can never succeed there and every running monitor on Windows
        # would have been reported dead. Found by reading the Windows branch
        # before shipping, not by the machine telling us.
        #
        # The cost is stated rather than buried: on Windows two monitors run
        # by the same interpreter are indistinguishable, so a reused pid
        # belonging to another perl process reads as alive. That is weaker
        # than the Unix guarantee and it is still stronger than pid alone.
        # It is the same shape as this file's neighbour already accepting that
        # tasklist reports no start time, and leaving the age undefined rather
        # than inventing one.
        return 1 if $Tira::WINDOWS && _same_program( $wanted, $seen );
        return 0;
    }
    return 0;
}

# Do these two name the same program, ignoring path, extension and case? Only
# consulted on Windows, where the process table has nothing else to offer.
sub _same_program {
    my ( $wanted, $seen ) = @_;
    my ($program) = split ' ', $wanted;
    return 0 if !defined $program || $program eq '' || $seen eq '';

    for my $name ( \$program, \$seen ) {
        ${$name} =~ s{\A.*[\\/]}{};
        ${$name} =~ s{[.]exe\z}{}i;
        ${$name} = lc ${$name};
    }
    return $program eq $seen ? 1 : 0;
}

sub job_delete {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "A job id is required\n" if !defined $args{id} || $args{id} eq '';
    return $self->_with_project_lock( $root, sub {
        my $jobs = _job_read( $self, $root );
        my $job  = _job_find( $jobs, $args{id} );
        $self->_write_json( _job_path( $self, $root ),
            [ grep { $_->{id} ne $args{id} } @{$jobs} ] );
        return $job;
    } );
}

# Is this job due at this instant? The instant is ALWAYS an argument - never
# the wall clock - so an assertion is about the schedule rather than about
# when the suite happened to run, which is the same reason every other dated
# behaviour in this engine takes an injected clock.
sub job_is_due {
    my ( $self, $job, $when ) = @_;
    return 0 if !$job;
    return 0 if exists $job->{enabled} && !$job->{enabled};

    # A monitor runs continuously rather than on a tick, so it is never
    # "due" - asking is a category error, and answering yes would make the
    # police start it once a minute.
    my $schedule = $job->{schedule} // '';
    return 0 if $schedule eq 'monitor';

    my $sets = eval { _cron_parse($schedule) } or return 0;

    my ( $year, $month, $day, $hour, $minute ) =
      $when =~ /\A(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/
      or die "Cannot read the time '$when'\n";

    my $weekday = ( POSIX::mktime( 0, 0, 12, $day, $month - 1, $year - 1900 ) )
      ? ( localtime POSIX::mktime( 0, 0, 12, $day, $month - 1, $year - 1900 ) )[6]
      : 0;

    return 0 if !$sets->[0]{ $minute + 0 };
    return 0 if !$sets->[1]{ $hour + 0 };
    return 0 if !$sets->[2]{ $day + 0 };
    return 0 if !$sets->[3]{ $month + 0 };

    # Sunday is both 0 and 7 in cron, and a schedule naming either means the
    # same day.
    return 0 if !$sets->[4]{$weekday} && !( $weekday == 0 && $sets->[4]{7} );
    return 1;
}

1;

__END__

=head1 NAME

Tira::Job - repeated jobs, a schedule the board owns

=head1 DESCRIPTION

A repeated job carries a schedule - a crontab expression or the literal
C<monitor> - and either a command to run or a message to announce, and the
police acts on it when it comes due. EPC-014.

It exists because a schedule that lived in a session died with it: three
standing hunts stopped and went unnoticed for hours, since a loop that has
stopped and a loop with nothing to report look identical from outside. A
schedule on the board is visible, durable and policeable.

=head1 THE REFUSAL IS THE POINT

A malformed schedule is rejected by C<job_add> and C<job_update> when it is
written, naming the field that was wrong and the range it takes, and nothing
is stored. This is deliberate rather than defensive: a job whose cron is
nonsense would never fire, and a job that never fires is indistinguishable
from a job with nothing to say - which is precisely the ambiguity this
feature was built to remove. Storing it would rebuild that ambiguity one
layer down.

=head1 A JOB IS ONE MODE OR THE OTHER

Either a command, whose output the police sends to the bridge, or a message
it announces directly. Never both - a record carrying both cannot say which
the bridge should get - and never neither. C<mode> records which, so a reader
never has to infer it from which field happens to be populated.

=head1 A MONITOR IS KNOWN TO BE ALIVE BY A PID AND WHEN IT STARTED

C<job_started> records the pid a monitor was started as, and
C<job_monitor_alive> decides whether it is still running by finding that pid
in the process table B<and> matching the command it is running.

The START TIMES are what decide it when both are known, and the command is
consulted only when one is missing. That order is the fix for TKT-860: comparing
commands first reported every C<d2>-wrapped monitor as B<dead>, because C<d2>
execs perl with the resolved path and the stored string never appears in the
child's argv. Nearly every command on this board begins with C<d2>, so the rule
written to end a silence cried on every pass instead - and the false-dead
reading also defeated the already-running refusal, so C<job.start> would launch
a second copy and orphan the first.

Both halves are still load-bearing. Asking C<kill 0, $pid> is this
distribution's own precedent - C<police_claim_singleton> has done exactly that
since it was written - and for a singleton claimed seconds ago it is correct. It is not
correct for a monitor whose pid may have been recorded days ago, because pids
are reused, and a reused pid answers C<kill 0> in the affirmative. A liveness
check built on that alone would report a dead monitor as B<alive>, which is
the same silence the C<monitor-dead> rule exists to end, rebuilt inside the
fix for it.

The process table arrives as B<data>. This module never reads it: the engine
is forbidden C<qx>, C<system>, C<exec> and piped C<open> - the guard excludes
only C<lib/Tira/CLI> - and reading the table needs C<ps> or C<tasklist>. So
C<Tira::CLI::Police::_running_processes> gathers the facts and this decides
from them, which is also what lets the tests cover every case without a real
process.

What this deliberately does not detect is a monitor that is alive but
B<wedged> - the process is up and whatever it was polling has stopped. That
would need the monitor to report progress rather than merely exist, which
needs the monitored thing to cooperate; every monitor this feature was built
to absorb is an existing command that will never write a heartbeat. A check
believed to cover more than it does is worse than one that says where it
stops.

=head1 CALL IT THROUGH TIRA

C<Tira> is the public entry point and keeps a forwarder for each verb here,
requiring this module at the call site. Every sub takes C<$self> - a blessed
C<Tira> - as its first argument.

=cut
