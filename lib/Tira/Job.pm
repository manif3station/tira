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
# IN ITS OWN MODULE FROM THE START. TKT-746 is decomposing lib/Tira.pm - four
# concerns lifted so far, 15,264 lines down to 14,164, measured at the fourth
# lift rather than carried forward (TKT-876 is what happens when it is carried
# forward) - so new code goes beside those rather than into the file they are
# being pulled out of. Tira keeps thin forwarders that require this lazily, the
# same shape Tira::Toon, Tira::Tasklist, Tira::Render and Tira::Attachment
# already use.

use strict;
use warnings;

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

    # HOW OFTEN THIS MONITOR EXPECTS TO SPEAK, in minutes. His answer to Q-115
    # on TKT-863, choosing it over a board-wide constant and over deriving it:
    # "Each monitor declares its own expectation when it is created - a field
    # like 'expect a line every N minutes', empty meaning no expectation and a
    # dim light."
    #
    # Per-job because there is nothing to derive it from - a monitor's schedule
    # is the literal string 'monitor' - and because a constant cannot fit both a
    # poller that should speak every minute and JOB-005, which is legitimately
    # quiet for over an hour because it only speaks when the owner goes away.
    #
    # EMPTY IS NOT ZERO AND NOT A DEFAULT. Undeclared means no expectation at
    # all, and the dashboard shows dim rather than judging. A default here would
    # be the board-wide constant he turned down, arriving through the back door.
    # HOW LONG TO WAIT BEFORE RUNNING IT AGAIN, when the command ends. His voice
    # 6694 on TKT-891: an option called looping, off by default, and when it is
    # on "the user does not have to type the while loop - they only type the
    # middle part, the thing they want to run".
    #
    # It comes from JOB-006, which was a while loop typed into a command field
    # to keep police alive and never ran once. A command containing a loop is
    # one opaque string: nothing can report the interval, tell a supervised job
    # from a plain one, or count restarts. A field can be seen.
    #
    # A LOOP CAN ONLY WRAP A COMMAND, which is his own reason for it not
    # applying in message mode, and a cron job is the same case from the other
    # side - it fires on a tick and is not up between runs.
    my $restart = $args{restart_every};
    $restart = undef if defined $restart && $restart eq '';
    if ( defined $restart ) {
        die "Restarting belongs to a 'monitor' job - a cron job fires on a "
          . "tick rather than staying up, so there is nothing to restart\n"
          if $kind ne 'monitor';
        die "A loop can only wrap a command - a message job announces its text "
          . "and runs nothing, so there is nothing to restart\n"
          if !$has_command;
        die "How long to wait before restarting is a whole number of seconds, "
          . "greater than zero - '$restart' is not\n"
          if $restart !~ /\A[1-9][0-9]*\z/;
    }

    my $expect = $args{expect_every};
    $expect = undef if defined $expect && $expect eq '';
    if ( defined $expect ) {
        die "An expectation belongs to a 'monitor' job - a cron job is not "
          . "supposed to be up between runs, so it has no heartbeat to miss\n"
          if $kind ne 'monitor';
        die "How often a monitor expects to speak is a whole number of "
          . "minutes, greater than zero - '$expect' is not\n"
          if $expect !~ /\A[1-9][0-9]*\z/;
    }

    return (
        schedule      => $schedule,
        schedule_kind => $kind,
        mode          => $has_command ? 'command' : 'message',
        command       => $has_command ? $args{command} : undef,
        message       => $has_message ? $args{message} : undef,
        expect_every  => defined $expect ? 0 + $expect : undef,
        restart_every => defined $restart ? 0 + $restart : undef,
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

# How many of a monitor's lines one police pass will carry to the bridge.
#
# THE CAP IS PER PASS AND ANNOUNCED. A chatty poller must not be able to fill
# the bridge, but a bridge that truncates silently is a bridge that lies - this
# epic exists because silence and nothing-to-say looked identical - so the
# caller is handed the count it did not get as well as the lines it did.
our $MONITOR_OUTPUT_LINES = 20;

# Read through a call rather than reached for as a package variable. The police
# pass lives in Tira.pm and loads this module at runtime, so a fully-qualified
# name there is a symbol the compiler has never seen - which Perl reports as a
# possible typo, and which would be one the day this is renamed.
sub monitor_output_per_pass { return $MONITOR_OUTPUT_LINES }

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

            # Carried like the schedule, and for the same reason: an update
            # naming only the command must not silently drop how often this
            # monitor said it would speak. A new field that vanishes when
            # something else is touched is worse than no field, because it
            # looks set.
            expect_every => exists $args{expect_every}
              ? $args{expect_every}
              : $job->{expect_every},

            # Carried for the same reason, and it matters more here: a job that
            # silently stopped being supervised would look supervised on the
            # card and let its command die unnoticed.
            restart_every => exists $args{restart_every}
              ? $args{restart_every}
              : $job->{restart_every},
            ( defined $args{command} ? ( command => $args{command} )
              : defined $args{message} ? ( message => $args{message} )
              : $job->{mode} eq 'command' ? ( command => $job->{command} )
              : ( message => $job->{message} ) ),
        );
        my %fields = _job_fields(%merged);

        # ONLY WHAT WOULD MAKE THE RECORD UNTRUE - and the first version of this
        # comment got one of them wrong, which is worth leaving on the record.
        # It said "changing the schedule of a running monitor is harmless - it
        # is already running, and 'monitor' is what it stays". THE SECOND HALF
        # IS FALSE: a schedule of '0 * * * *' makes it a CRON job, keeps the
        # pid, and job_monitor_alive answers 0 for anything that is not a
        # monitor - so the process goes on running with nothing on the board
        # watching it. That is TKT-870's fault reached by another door, left
        # open by the guard written to close it.
        #
        # So the schedule is refused when it would change the KIND. Monitor to
        # monitor really is harmless and stays allowed; monitor to cron is the
        # case above.
        #
        # Found by a review challenging the sentence, not by a test - the tests
        # asserted the three refusals and never asked what else could make the
        # record untrue.
        _refuse_while_running( $job, 'changing it from a monitor to a cron job' )
          if defined $args{schedule}
          && $args{schedule} ne 'monitor'
          && ( $job->{schedule_kind} // '' ) eq 'monitor';

        # Changing the COMMAND makes the board name something the pid is not
        # executing, and DISABLING it makes monitor-dead go silent about a
        # process that is still there. TKT-868, TKT-870.
        _refuse_while_running( $job, 'changing its command' )
          if defined $args{command}
          && $args{command} ne ( $job->{command} // '' );
        _refuse_while_running( $job, 'disabling it' )
          if defined $args{enabled} && !$args{enabled} && $job->{enabled};

        %{$job} = ( %{$job}, %fields );
        $job->{enabled} = $args{enabled} ? 1 : 0 if defined $args{enabled};
        $job->{last_updated} = $self->{clock}->();
        $self->_write_json( _job_path( $self, $root ), $jobs );
        return $job;
    } );
}

# What a monitor said, told to the board by the monitor itself. TKT-851, after
# his answer to Q-112: "each output will be registered who talked to the police."
#
# WHY THIS AND NOT A SPOOL TAIL, which is what this card built first: following a
# file tells police WHAT was said. A monitor calling in tells it that THIS
# monitor said it, at this moment - and a monitor that has not called in for an
# hour is a fact about the monitor, where a file nobody has written to is not.
# TKT-873's silence rule needs the former and cannot be built on the latter.
#
# BOUNDED, because the feeder writes continuously and police may not read for
# thirty seconds. The buffer keeps the NEWEST lines - what a poller is saying now
# beats how its flood began - and counts what it could not keep, because a buffer
# that drops quietly is the silent loss this whole epic exists to end.
our $MONITOR_OUTPUT_HELD = 200;

# What a monitor's own CARD shows, which is a different question from what the
# queue above holds.
#
# The queue is a HANDOVER: the feeder fills it, the police pass takes what it
# announced, and it is meant to be emptied. So a card reading it finds nothing a
# second after the monitor spoke - which is why a second, smaller thing exists.
# His report, 2026-09-04: "why only 1 job got the tail logs?", beside a
# screenshot of two running monitors whose cards showed nothing at all.
#
# ONE DELIVERY'S WORTH, matched to the feeder's batch rather than invented: the
# feeder hands over $Tira::CLI::Job::BATCH_LINES at a time, so a card showing the
# last batch shows what the board most recently heard. A number chosen freely
# here would be a third constant nobody could reason about against the two above.
#
# WRITTEN OUT RATHER THAN REFERENCED, deliberately: $BATCH_LINES belongs to
# Tira::CLI::Job, and the engine does not depend on the CLI - that direction is
# the whole reason liveness is decided from a table the CLI gathers and hands
# over. So the value is mirrored and t/532 asserts the two stay equal, which
# catches the drift a shared reference would have prevented at the cost of the
# dependency. TKT-922.
our $MONITOR_RECENT_KEPT = 25;

sub monitor_recent_kept { return $MONITOR_RECENT_KEPT }

sub job_feed {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "A job id is required\n" if !defined $args{id} || $args{id} eq '';

    my @lines = grep { defined && /\S/ } @{ $args{lines} || [] };
    s/\r\z// for @lines;
    return if !@lines;

    return $self->_with_project_lock( $root, sub {
        my $jobs = _job_read( $self, $root );
        my $job  = _job_find( $jobs, $args{id} );

        my @held = ( @{ $job->{output} || [] }, @lines );
        my $over = @held - $MONITOR_OUTPUT_HELD;
        if ( $over > 0 ) {
            @held = @held[ -$MONITOR_OUTPUT_HELD .. -1 ];
            $job->{output_dropped} = ( $job->{output_dropped} || 0 ) + $over;
        }
        $job->{output} = \@held;

        # AND THE CARD'S OWN COPY, which the drain never touches. Everything
        # above is about the queue the police pass empties; this is what is left
        # for somebody looking at the dashboard. Kept newest-first-out for the
        # same reason the queue is: a card shows what is true now, and a tail
        # that dropped the newest would show a monitor's first minutes for ever.
        # TKT-922.
        my @recent = ( @{ $job->{recent} || [] }, @lines );
        @recent = @recent[ -$MONITOR_RECENT_KEPT .. -1 ]
          if @recent > $MONITOR_RECENT_KEPT;
        $job->{recent} = \@recent;

        # THE REGISTRATION. This is the whole difference from a spool: the board
        # now knows when this monitor last spoke, rather than when a file last
        # changed.
        $job->{last_output_at} = $self->{clock}->();
        $job->{last_updated}   = $self->{clock}->();
        $self->_write_json( _job_path( $self, $root ), $jobs );
        return $job;
    } );
}

# What police takes on its pass, and it TAKES rather than reads - the lines are
# removed, so nothing is announced twice and there is no offset to keep. That is
# the simplification the feeder buys: with a spool, "how far have I read" had to
# be stored and could disagree with the file (TKT-871). A queue that is drained
# cannot disagree with itself.
#
# DRAINING NOTHING MUST NOT LOOK LIKE SPEAKING. last_output_at is untouched here
# - only job_feed moves it - because TKT-873 reads it as "when did this monitor
# last call in", and a pass that found an empty queue has learned nothing about
# the monitor at all.
sub job_output_drain {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "A job id is required\n" if !defined $args{id} || $args{id} eq '';

    # A STRUCTURE THROUGH THE LOCK, unpacked outside it. _with_project_lock does
    # not preserve list context, so returning a two-element list from inside
    # collapses to its last value - which showed up as the drained lines
    # arriving as the number 0.
    my $taken = $self->_with_project_lock( $root, sub {
        my $jobs = _job_read( $self, $root );
        my $job  = _job_find( $jobs, $args{id} );

        my @held = @{ $job->{output} || [] };
        my $have = $job->{output_dropped} || 0;

        # HOW MANY WERE ANNOUNCED, not "whatever is here now". Police reads the
        # buffer during the pass and drains after the bridge write, and the
        # monitor may have called in during the gap. Taking everything would
        # discard lines nobody announced - losing a monitor's output silently,
        # which is the single failure this rule exists to prevent, arriving
        # through the fix for it. Lines are added at the BACK, so removing the
        # first N removes exactly the N that were read.
        my $count = defined $args{count} ? $args{count} : scalar @held;
        $count = @held if $count > @held;

        # AND NEVER MORE THAN SURVIVED. Taking N off the front is right only
        # while nothing trims the front in between - and job_feed trims exactly
        # there when the buffer overflows, keeping the newest and discarding the
        # oldest. So a chatty monitor between the read and this drain shifts the
        # queue out from under the count, and the first N become lines nobody
        # has heard.
        #
        # Measured before the fix: 200 announced, 200 more fed, and the drain
        # took NEW-1..NEW-200 - two hundred lines the bridge never saw, with the
        # dropped counter accounting for none of them.
        #
        # The overflow already tells us how many of the announced lines are
        # gone, so the count is reduced by exactly that. What is left at the
        # front is still the oldest surviving announced lines; anything the
        # overflow removed was announced and lost, which is a real loss the
        # dropped counter reports, rather than a silent one this drain adds to.
        #
        # THE EXISTING CODE GUARDED THE OTHER HALF OF THIS. Its comment already
        # says taking everything "would discard lines nobody announced", and it
        # is right - the count stops the buffer having GROWN from costing us.
        # This stops it having SHRUNK. TKT-893, found by the hourly hunt.
        # Likewise for the drops: subtracted rather than zeroed, because the
        # buffer may have overflowed again between the read and the write and
        # that count is a real loss somebody still has to be told about.
        my $dropped = defined $args{dropped} ? $args{dropped} : $have;
        $dropped = $have if $dropped > $have;

        # ONLY WHEN THE CALLER SAID WHAT IT ANNOUNCED. Without a count this is
        # "take what is here now", there was no gap between a read and this
        # call, and nothing in the buffer is unannounced - so subtracting drops
        # would refuse to drain a chatty monitor at all. The first version of
        # this guard did exactly that and t/503 caught it: 500 lines fed, every
        # one of them left in place.
        if ( defined $args{count} ) {
            my $trimmed = $have - $dropped;
            $trimmed = 0 if $trimmed < 0;
            $count -= $trimmed;
            $count = 0 if $count < 0;
        }

        return { lines => [], dropped => 0 } if !$count && !$dropped;

        my @lines = splice @held, 0, $count;
        $job->{output}         = \@held;
        $job->{output_dropped} = $have - $dropped;
        $job->{last_updated}   = $self->{clock}->();
        $self->_write_json( _job_path( $self, $root ), $jobs );
        return { lines => \@lines, dropped => $dropped };
    } );
    return ( $taken->{lines}, $taken->{dropped} );
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

# A monitor stops, and the board stops pointing at its process. TKT-893, from
# the decision recorded as KD13: the board never silently claims something
# false, so update, delete and disable refuse while a monitor is running - and a
# refusal is only actionable if there is something to act with. This is it, and
# TKT-892's Stop button is the other reason it exists.
#
# IT SUCCEEDS WHETHER OR NOT THE PROCESS IS THERE, which is the part worth
# understanding. The engine cannot read the process table - it is forbidden qx,
# system, exec and piped open, which is why liveness is decided from a table the
# CLI gathers and hands over. So all this knows is whether a pid was RECORDED.
# A pid whose process has already died is exactly the case somebody needs to
# clear, and refusing to clear it would leave the record wrong for ever with no
# way out. Stopping is therefore "the board is no longer responsible for that
# pid", and killing the process is what it does on the way if it is still there.
sub job_stop {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "A job id is required\n" if !defined $args{id} || $args{id} eq '';

    return $self->_with_project_lock( $root, sub {
        my $jobs = _job_read( $self, $root );
        my $job  = _job_find( $jobs, $args{id} );
        die "Job $args{id} is a cron job, not a monitor - a cron job is not up "
          . "between runs, so there is nothing to stop\n"
          if ( $job->{schedule_kind} // '' ) ne 'monitor';

        my $pid = $job->{pid};

        # Signalling is the caller's to do, not the engine's: killing needs a
        # process table to be sure of what is being killed, and this module
        # deliberately cannot reach one. The pid is returned so the CLI can act
        # on it, and the record is cleared either way - a board pointing at a
        # process nobody is responsible for is the fault this closes.
        $job->{pid}          = undef;
        $job->{started_at}   = undef;
        $job->{last_updated} = $self->{clock}->();
        $self->_write_json( _job_path( $self, $root ), $jobs );
        return { %{$job}, stopped_pid => $pid };
    } );
}

# What update, delete and disable all ask before changing a monitor. Named once
# because three callers asking the same question three ways is how they came to
# give three different answers. TKT-868, TKT-869, TKT-870.
sub _refuse_while_running {
    my ( $job, $what ) = @_;
    return if ( $job->{schedule_kind} // '' ) ne 'monitor';
    return if !defined $job->{pid} || $job->{pid} eq '';
    die "Job $job->{id} is running as pid $job->{pid}, so $what would leave the "
      . "board saying something untrue about it. Stop it first:\n"
      . "  d2 tira.job.stop --id $job->{id}\n"
      . "That clears the record even if the process has already gone.\n";
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
# The schedule, in words a person can check at a glance. TKT-884, inside
# TKT-892: the card face showed the raw cron string, so the one place a schedule
# is visible was the one place it could not be read.
#
# HERE RATHER THAN IN THE PAGE, and deliberately. lib/Tira/CLI/Browser.pm already
# refuses to let the browser interpret a schedule - job_check asks the ENGINE
# whether a crontab is valid instead of running a regex in JavaScript, because
# two validators for one format is how the engine and the browser came to
# disagree about attachment content types (TKT-713). A cron-to-English
# translator written in the page would be a second reading of the same format,
# free to drift from the first in exactly the way that comment exists to
# prevent. So the row carries the words and the page renders a string it is not
# asked to understand.
#
# AND IT REFUSES TO GUESS. Everything it cannot describe with CERTAINTY comes
# back as itself. A description that is nearly right is worse than none: it
# would be read, believed, and the cron would never be looked at again - which
# is precisely the failure this card is fixing, one layer along. Every shape
# below is one whose meaning is unambiguous from the five fields alone.
# How a job command becomes a list of arguments.
#
# TKT-898. It was split ' ' at three sites, so any argument containing a space
# was torn into pieces - and the job ran, exited 0, and did the wrong thing:
#
#   stored : d2 tira.comment.add --ref TKT-1 --text "two words"
#   ran as : [d2] [tira.comment.add] [--ref] [TKT-1] [--text] ["two] [words"]
#
# THE CONFUSION WAS BETWEEN TWO THINGS A SHELL DOES. It GROUPS arguments and it
# INTERPRETS metacharacters. TKT-851 removed the shell to stop the second, and
# took the first with it - which was never the intention: its own worked
# examples pass --message strings with spaces in them.
#
# shellwords GROUPS AND DOES NOT INTERPRET, which is exactly the missing half. A
# semicolon, a backtick, a $(...) or a redirect inside a quoted argument comes
# back as literal text, so TKT-851's guarantee is untouched: nothing of the job's
# becomes shell source, and the six injection attempts it was proved against are
# still contained.
#
# AN UNPARSEABLE COMMAND FALLS BACK TO THE OLD SPLIT rather than dying. An
# unbalanced quote is a mistake somebody will make, and the honest failure for it
# is the command not running - which the runnable check and the executor already
# report - rather than a job that vanishes with a parse error from inside a
# module nobody was looking at.
sub job_command_words {
    my ($command) = @_;
    return () if !defined $command || $command !~ /\S/;

    # WRITTEN OUT RATHER THAN Text::ParseWords, and the reason is Windows.
    # shellwords is POSIX-shell-like and treats a backslash as an ESCAPE, so
    # C:\strawberry\perl\bin\perl.exe comes back as C:strawberryperlbinperl.exe -
    # every separator eaten. t/493 caught it immediately, asserting that a full
    # path and a .exe on either side still name the same program. This board runs
    # on Windows too, where a job command is far more likely to contain
    # backslashes than escapes.
    #
    # So: quotes GROUP, and everything else is literal. That is the whole of what
    # was missing. A backslash, a semicolon, a backtick or a $(...) inside an
    # argument is text, which keeps TKT-851's guarantee exactly as it was - the
    # words still arrive as positional parameters and nothing of the job's
    # becomes shell source.
    my @words;
    my $current = '';
    my $started = 0;
    my $quote   = '';

    for my $character ( split //, $command ) {
        if ($quote) {
            if   ( $character eq $quote ) { $quote = '' }
            else                          { $current .= $character }
            next;
        }
        # A QUOTE ONLY GROUPS AT THE START OF A WORD. Anywhere else it is an
        # ordinary character, which is what keeps `can't` a word and
        # C:\O'Reilly\tool.exe a path - both of which split perfectly well before
        # this card and would otherwise now DIE as an unbalanced quote. A review
        # found that; the first version made every quote syntactic and turned an
        # apostrophe in ordinary text into a job that refuses to run.
        #
        # The cost is that x"y z"w does not group the way a shell would. That is
        # the safe direction: it splits exactly as it did before, and the rule
        # this card promised is that an UNQUOTED command is unchanged.
        if ( ( $character eq q{"} || $character eq q{'} )
            && !$started
            && $current eq '' )
        {
            $quote   = $character;
            $started = 1;
            next;
        }
        if ( $character =~ /\s/ ) {
            if ( $started || length $current ) {
                push @words, $current;
                $current = '';
                $started = 0;
            }
            next;
        }
        $current .= $character;
        $started = 1;
    }

    # AN UNBALANCED QUOTE IS REFUSED, and this is the card's own instruction
    # rather than my first instinct - which was to fall back to the old split.
    # That fallback was wrong twice over: it runs something the author did not
    # write, and it does so silently, which is the exact shape this epic exists
    # to remove.
    #
    # Refused HERE rather than by returning an empty list, because empty already
    # means something else at both call sites - "the job has no command to run" -
    # and a job whose command is a typo is not a job with no command. The
    # difference is what somebody reads when they go looking.
    die "Job command has an unbalanced $quote quote, so it cannot be read as "
      . "arguments: $command\n"
      if $quote;

    push @words, $current if $started || length $current;
    return @words;
}

# The names cron accepts for a weekday, so "sun" reads as well as "0". Cron takes
# both and a person writing a schedule by hand usually takes the word.
my @DAY = qw(Sunday Monday Tuesday Wednesday Thursday Friday Saturday);

my %DAY_NAME = (
    sun => 0, mon => 1, tue => 2, wed => 3, thu => 4, fri => 5, sat => 6,
);

my @MONTH = qw(January February March April May June
               July August September October November December);

my %MONTH_NAME = do {
    my $n = 0;
    map { ( lc substr( $_, 0, 3 ) => ++$n ) } @MONTH;
};

# 1st, 2nd, 3rd, 4th - because "on the 1 of each month" is the kind of wording a
# reader stops on instead of reading the schedule.
sub _ordinal {
    my ($n) = @_;
    return "${n}th" if $n % 100 >= 11 && $n % 100 <= 13;
    my %suffix = ( 1 => 'st', 2 => 'nd', 3 => 'rd' );
    return $n . ( $suffix{ $n % 10 } // 'th' );
}

# A list of things as a sentence rather than as data: "08:00, 12:00 and 18:00".
# IS THIS EVERY-N, or does it just look like it? Cron restarts a step at the
# start of its range, so */7 on minutes fires at 0,7,...,56 and then 0 - a gap of
# FOUR, not seven - and */5 on hours leaves a four-hour gap at midnight. "Every 7
# minutes" is the nearly-right description this sub exists to refuse.
#
# ASKED OF THE EXPANDED VALUES RATHER THAN THE TEXT, which is stronger than the
# divisibility test it replaces: it answers for ranges and lists too, and it
# includes the WRAP - the gap from the last value back to the first - which is
# exactly where */7 stops being every-seven.
# WHAT MAKES A DESCRIPTION APPROXIMATE, said in the description itself. His
# answer to Q-119: "Describe everything, marking the approximate ones as
# approximate - e.g. 'About every 7 minutes (restarts each hour)'".
#
# The mark and the REASON travel together on purpose. "About every 7 minutes" on
# its own is a hedge; with "(restarts each hour)" it is an explanation, and a
# reader who needs the exact firing times knows where the imprecision is.
# " every Monday", " every weekday", " every weekend day" - or undef when the
# field selects no day or all of them, which is not a restriction worth wording.
sub _weekday_phrase {
    my ($selected) = @_;
    # 7 IS SUNDAY AS WELL AS 0, which is standard cron.
    my %once;
    my @day = sort { $a <=> $b }
      grep { !$once{$_}++ } map { $_ == 7 ? 0 : $_ } @{$selected};
    return undef if @day == 0 || @day == 7;
    return ' every weekday'     if @day == 5 && "@day" eq '1 2 3 4 5';
    return ' every weekend day' if @day == 2 && "@day" eq '0 6';
    return ' every ' . _and_list( map { $DAY[$_] } @day );
}

# " on the 1st of each month", " on 1 January", " every day in March"
sub _monthday_phrase {
    my ( $dom, $mon, $values ) = @_;
    my @date  = @{ $values->{'day of month'} };
    my @month = @{ $values->{month} };
    return undef if !@date || !@month;

    my $which = $dom eq '*' ? '' : _and_list( map { _ordinal($_) } @date );
    return " on the $which of each month" if $mon eq '*';
    return ' every day in ' . _and_list( map { $MONTH[ $_ - 1 ] } @month )
      if $dom eq '*';
    my $phrase = " on $which " . _and_list( map { $MONTH[ $_ - 1 ] } @month );
    $phrase =~ s/(\d+)(?:st|nd|rd|th)/$1/g;
    return $phrase;
}

sub _about {
    my ( $phrase, $why ) = @_;
    return "About $phrase ($why)";
}

sub _even_step {
    my ( $values, $size ) = @_;
    return undef if @{$values} < 2;
    my $step = $values->[1] - $values->[0];
    for my $i ( 2 .. $#{$values} ) {
        return undef if $values->[$i] - $values->[ $i - 1 ] != $step;
    }

    # AND THE WRAP, which is the gap this whole guard exists for. */7 on minutes
    # has seven between every pair and FOUR from 56 back to 0; 0-20/2 on hours
    # has two between every pair and four from 20 back to 0. Checking only the
    # pairs would call both of them even, which is the exact sentence this sub
    # refuses to write.
    return undef if $size - $values->[-1] + $values->[0] != $step;
    return $step;
}

sub _and_list {
    my (@item) = @_;
    return $item[0] if @item == 1;
    my $last = pop @item;
    return join( ', ', @item ) . " and $last";
}

sub job_schedule_words {
    my ( $schedule, $restart_every ) = @_;
    return '' if !defined $schedule;

    # A LOOPING MONITOR SAYS SO. His report, 2026-09-04: "If I job original added
    # as a loop and sleep for 5 seconds... didn't show on the card that is a
    # loop." restart_every appears three times in the jobs view and all three are
    # the editor or the save, so the board showed a looping monitor and a
    # one-shot one identically. TKT-915.
    #
    # ADDED TO THE PHRASE RATHER THAN REPLACING IT, because both things are true
    # and the first is the more important: it does run continuously, and the
    # interval is how it comes back when the command inside it ends.
    #
    # THE SECOND ARGUMENT IS OPTIONAL AND MUST STAY SO. Tira::CLI::Browser calls
    # this with a schedule alone, and t/517 asserts a dozen cron phrasings
    # through the one-argument form - a required parameter here would take the
    # whole schedule column with it.
    if ( $schedule eq 'monitor' ) {
        return 'Runs continuously' if !$restart_every;
        my $unit = $restart_every == 1 ? 'second' : 'seconds';
        return "Runs continuously, restarting $restart_every $unit after it ends";
    }

    my @field = split /\s+/, $schedule;
    return $schedule if @field != 5;
    my ( $min, $hour, $dom, $mon, $dow ) = @field;

    # THE OR TRAP, AND IT IS THE ONE THING IN CRON MOST OFTEN GOT WRONG. When
    # BOTH day fields are restricted cron ORs them: "0 0 1 * 1" fires on the 1st
    # of the month AND on every Monday, not on Mondays that fall on the 1st.
    #
    # IT IS DESCRIBED RATHER THAN REFUSED, on his answer to Q-119 - and NOT
    # marked "About", because it is not approximate. It is exact and surprising,
    # and a hedge would describe the wrong difficulty. What it needs is the OR
    # said outright, which "and also" does and no shorter phrasing does. TKT-917.
    my $both_days = $dom ne '*' && $dow ne '*';

    # THE EXPANDER THIS MODULE ALREADY HAS, not a second one. _cron_field_values
    # and %CRON_FIELDS have parsed every cron field since _cron_parse was
    # written - steps, ranges, lists and cron's own "5/10" - and they are the
    # validator the write path uses. I wrote a rival by the same name here and
    # it silently REDEFINED the original, which is how a fresh sub with the same
    # name behaves in Perl: the later one wins and everything that called the
    # first gets the second. TKT-917.
    # NAMES FIRST. Cron accepts "sun" and "jan" and a person writing a schedule
    # by hand usually writes them; _cron_field_values takes numbers, so they are
    # turned into numbers here rather than by teaching the validator a second
    # syntax it would then have to refuse consistently.
    my @field_text = @field;
    $field_text[3] =~ s/([a-z]{3,})/exists $MONTH_NAME{lc $1} ? $MONTH_NAME{lc $1} : $1/gie;
    $field_text[4] =~ s/([a-z]{3,})/exists $DAY_NAME{lc $1}   ? $DAY_NAME{lc $1}   : $1/gie;

    my %values;
    for my $i ( 0 .. 4 ) {
        my $set = _cron_field_values( $field_text[$i], $CRON_FIELDS[$i] );
        return $schedule if !$set;
        $values{ $CRON_FIELDS[$i]{name} } = [ sort { $a <=> $b } keys %{$set} ];
    }
    my $minutes = $values{minute};
    my $hours   = $values{hour};


    # WHICH DAYS, as a phrase appended to whatever the time reads as. Empty when
    # the schedule runs every day, which is the common case and needs no words.
    my $on_day = '';
    my $also   = '';
    if ( $both_days ) {
        # Both halves, joined by "and also" - the one phrasing that cannot be
        # read as an AND of the two conditions.
        $also = _weekday_phrase( $values{'day of week'} );
        return $schedule if !defined $also;
        my $dates = _monthday_phrase( $dom, $mon, \%values );
        return $schedule if !defined $dates;

        # "and also" rather than "and", because "and" reads as an AND of the two
        # conditions - which is the misreading this whole branch exists to stop.
        $on_day = "$dates, and also$also";
    }
    elsif ( $dow ne '*' ) {
        $on_day = _weekday_phrase( $values{'day of week'} );
        return $schedule if !defined $on_day;
    }
    elsif ( $dom ne '*' || $mon ne '*' ) {
        $on_day = _monthday_phrase( $dom, $mon, \%values );
        return $schedule if !defined $on_day;
    }

    # --- and now the time of day ---------------------------------------------

    my $every_minute = @{$minutes} == 60;
    my $every_hour   = @{$hours} == 24;

    if ($every_minute) {
        return "Every minute$on_day" if $every_hour;
        return $schedule;
    }

    # A minute STEP, which is only every-N when N divides the hour. Cron restarts
    # the step at the top of each hour, so */7 fires at 0,7,...,56 and then 0 - a
    # gap of FOUR minutes, not seven. _cron_field_values refuses those, so
    # anything that reaches here with several minutes is an honest step.
    if ( @{$minutes} > 1 ) {
        return $schedule if !$every_hour;
        my $step = _even_step( $minutes, 60 );
        return "Every $step minutes$on_day" if $step && $step > 1;

        # NOT EVEN, SO IT IS MARKED RATHER THAN REFUSED. His answer to Q-119.
        # */7 fires at 0,7,...,56 then 0 - a gap of four - so "every 7 minutes"
        # would be false, and "About every 7 minutes (restarts each hour)" is
        # true, useful, and says where the imprecision is.
        if ( $field[0] =~ m{\A\*/([1-9][0-9]*)\z} ) {
            return _about( "every $1 minutes$on_day", 'restarts each hour' );
        }
        return $schedule;
    }

    # 0 + it, so a zero-padded field does not leak its padding into the words:
    # "09" is a perfectly good cron minute and a poor English one.
    my $at_minute = 0 + $minutes->[0];

    if ($every_hour) {
        return "Every hour, on the hour$on_day" if $at_minute == 0;
        # Singular at one, because "1 minutes past" is the kind of thing a
        # reader notices instead of the schedule.
        my $unit = $at_minute == 1 ? 'minute' : 'minutes';
        return "Every hour at $at_minute $unit past$on_day";
    }

    my $clock = sub { return sprintf '%02d:%02d', $_[0], $at_minute };

    # An hour STEP - his 0 */2 * * *. Same divisibility rule as the minute step,
    # against 24 rather than 60: */5 on hours fires at 0,5,10,15,20 then 0, a
    # four-hour gap, and _cron_field_values has already refused it.
    # A contiguous RANGE of hours is a range, not a step of one - and it is
    # tested before the step so "9-17" does not read as "every 1 hours".
    if ( @{$hours} > 1 && $hours->[-1] - $hours->[0] == $#{$hours} ) {
        return 'Every hour from '
          . $clock->( $hours->[0] ) . ' to ' . $clock->( $hours->[-1] ) . $on_day;
    }

    if ( @{$hours} > 2 && _even_step( $hours, 24 ) ) {
        my $step = _even_step( $hours, 24 );
        my $when = $at_minute == 0
          ? 'on the hour'
          : "at $at_minute " . ( $at_minute == 1 ? 'minute' : 'minutes' ) . ' past';
        return "Every $step hours, $when$on_day";
    }

    # A LIST of hours, which is how twice a day is written - and how an uneven
    # step is written too, since "At 00:00, 05:00, 10:00, 15:00 and 20:00" is
    # EXACTLY right where "every 5 hours" would not be. That is the distinction
    # this sub cares about: not whether a schedule is simple, but whether the
    # sentence is true.
    #
    # CAPPED AT SIX, because past that it stops being a sentence and becomes a
    # data dump - eleven times in a row is harder to check at a glance than the
    # cron it replaced, and the contract has always been that anything this sub
    # cannot say WELL it returns unchanged.
    if ( @{$hours} > 1 ) {
        return 'At ' . _and_list( map { $clock->($_) } @{$hours} ) . $on_day
          if @{$hours} <= 6;

        # TOO LONG TO READ, SO IT IS MARKED RATHER THAN LEFT AS CRON. Eleven
        # times in a row is exact and unreadable; "About every 2 hours from
        # 00:23 to 20:23" is inexact only at the wrap, readable, and honest
        # because it says so. His answer to Q-119.
        my $step = _even_step( $hours, 24 );
        my $gap  = $step || ( $hours->[1] - $hours->[0] );
        return _about(
            "every $gap hours from "
              . $clock->( $hours->[0] ) . ' to ' . $clock->( $hours->[-1] ) . $on_day,
            'restarts each day' );
    }

    my $at = 'at ' . $clock->( $hours->[0] );

    # "Every Monday at 09:00" rather than "Every week, on Monday, at 09:00" - the
    # day is the subject, and the shorter form is what a person would say.
    if ( $on_day =~ s/\A every // ) {
        return "Every $on_day $at";
    }
    return "At " . $clock->( $hours->[0] ) . $on_day if $on_day;
    return "Every day $at";
}

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

    # A LIVENESS CHECK MUST NOT DIE over a malformed command. This one is asked
    # about a job that already exists, on a path where the answer is "is this
    # process the one we started" - and a typo in a stored command is not a
    # reason to take the whole police pass down. Unreadable means unmatched.
    my ($program) = eval { job_command_words($wanted) };
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

        # The worst of the three, because it removes the only thing that could
        # have reported the orphan: once the job is gone, monitor-dead has no
        # record to notice the process by. TKT-869.
        _refuse_while_running( $job, 'deleting it' );

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

B<That paragraph was written before the monitors cooperated, and half of it is
now out of date.> TKT-851's feeder means every started monitor reports progress
by the act of speaking, and C<job_feed> stamps C<last_output_at> as it does. So
the missing ingredient exists. What is still true is that C<job_monitor_alive>
does not use it: this sub answers "is the process there", and nothing more.

Deciding a wedged monitor needs a second fact - how often this monitor ought to
speak - which the record could not supply, since a monitor's C<schedule> is the
literal string C<monitor>. TKT-863 asked the owner where that should come from
and he chose per-job declaration over a board-wide constant: C<expect_every>, a
whole number of minutes, and B<undeclared means no expectation> rather than a
default. The dashboard heartbeat reads it. A police rule that announces the
silence on the bridge is TKT-873, absorbed into TKT-893, and it will read the
same field rather than inventing a second notion of late.

=head1 WHAT THE BOARD SAYS ABOUT A PROCESS IT DID NOT START

TKT-893, grouping nine findings that turned out to be one: the board records a
monitor's pid and command when it starts, and until this card nothing kept that
record true afterwards.

Each verb answered differently and none of them said so. C<job_update> changed
the command while the pid went on running the old one. C<job_delete> removed the
record and left the process, taking with it the only thing C<monitor-dead> could
have reported the orphan by. Setting C<enabled> to 0 cleared nothing, and since
C<monitor-dead> is deliberately silent about a disabled monitor, that was the one
change making a live process invisible in both directions at once.

B<The rule is that the board never silently claims something false.> So the three
refuse while a monitor is running, through one shared C<_refuse_while_running> -
named once, because three callers asking the same question three ways is exactly
how they came to give three answers. Only what would make the record untrue is
refused: a running monitor's schedule may change while it stays a monitor, and
is refused when it would turn it into a cron job - which would keep the pid on a
record C<monitor-dead> no longer watches.

B<C<job_stop> succeeds whether or not the process is there, and signals nothing.>
That is the engine's own constraint deciding the shape rather than a preference:
this module is forbidden C<qx>, C<system>, C<exec> and piped C<open>, which is
why liveness is decided from a table L<Tira::CLI::Police> gathers and hands over.
So all it can know is that a pid was RECORDED. A pid whose process has already
died is precisely what somebody needs to clear, and refusing would leave the
record wrong for ever - the trap of a gate satisfiable only by giving up. The pid
comes back as C<stopped_pid> so the CLI, which is allowed to, can signal it.

B<And the record is cleared BEFORE the signal.> A signal that fails - the process
already gone, or owned by somebody else - must not leave the board still pointing
at a pid nobody is responsible for, which is the whole fault being closed.

B<That ordering is right and it hid a worse fault for a release.> Because the
record is cleared either way, a stop that signalled the whole monitor and a stop
that orphaned three quarters of it left the board in identical states - and until
5.45 the CLI signalled C<stopped_pid> alone, which is the shell owning the
pipeline, while the command and the feeder carried on. The board then held no pid
for a running monitor, C<job_monitor_alive> answered honestly that nothing was
running, and the duplicate-start refusal in C<job.start> let a second monitor
begin beside the first. Nothing here was wrong; what was missing was that the
signal reached one process of several. The CLI now signals the process group the
monitor was started in and reports which - C<group>, C<process> or C<gone> - so
the two outcomes are distinguishable at last. TKT-920.

=head1 KEEPING A COMMAND RUNNING

C<restart_every> is how a monitor says it should be started again when its
command ends. TKT-891, from his own JOB-006: a C<while> loop typed into a command
field to keep police alive, which never ran once.

B<A field rather than shell, because the board can see a field.> A command
containing a loop is one opaque string - nothing can report the interval, tell a
supervised job from a plain one, or count restarts.

The loop itself is in L<Tira::CLI::Job>'s fixed pipeline script, wrapping the
positional parameters. Nothing of the job's becomes shell source, which is
TKT-851's guarantee and is untouched: what is looped is the same C<"$@"> that was
exec'd before. Refused on a cron job, which fires on a tick rather than staying
up, and on a message job, because a loop can only wrap a command.

=head1 A COMMAND IS A PROGRAM AND ITS ARGUMENTS

C<job_command_words> turns a job's stored command into the list a process is
started with. Quotes GROUP; everything else is literal.

TKT-898. It was C<split ' '> at three sites, so C<--text "two words"> reached the
program as three arguments with the quote marks attached, and the job exited 0
having done the wrong thing. The confusion was between the two things a shell
does: it groups arguments and it interprets metacharacters. TKT-851 removed the
shell to stop the second and took the first with it.

B<Written out rather than using Text::ParseWords>, and Windows is the reason:
C<shellwords> treats a backslash as an escape, so
C<C:\strawberry\perl\bin\perl.exe> comes back with every separator eaten. That
was caught by the test asserting a full path and a C<.exe> on either side still
name the same program.

B<A quote only groups when it starts a word.> Anywhere else it is an ordinary
character, which is what keeps C<can't> one word and C<C:\O'Reilly\tool.exe> one
path. An adversarial review found the first version making every quote syntactic,
so an apostrophe in ordinary text died as an unbalanced quote - a regression
against this card's own promise that an unquoted command is unchanged. The cost
is that C<x"y z"w> does not group the way a shell would, which is the safe
direction: it splits exactly where it did before.

B<An unbalanced quote is refused>, naming the quote and showing the command back,
rather than falling back to the old split - which would run something the author
did not write, silently. It is refused here rather than by returning an empty
list, because empty already means "the job has no command to run" at both call
sites, and a job whose command has a typo in it is not a job with no command.

Two callers must not die of that refusal and do not: the police pass reports it
as a failed run carrying these words, since the bridge is the single reporting
path and one malformed command must not silence a whole pass; and the Windows
liveness comparator treats unreadable as unmatched, because it is asked whether a
process is the one we started and a typo is not a reason to stop answering.

=head1 A SCHEDULE THAT READS AS WORDS

C<job_schedule_words> reads the values a cron field B<selects> rather than the
text it was written as, using the same C<_cron_field_values> expander
C<_cron_parse> has always had. So a schedule is described by what it means:
C<0 0,4,8,12,16,20 * * *> reads as I<Every 4 hours> however it was typed.

That is also what makes the step check honest. It used to be C<60 % $step == 0>;
it now asks whether the gaps between the selected values are all equal
B<including the wrap> - the half divisibility could not see, since C<0-20/2> has
two between every pair and B<four> from 20 back to 0, which is exactly where
I<every 2 hours> stops being true.

B<Nothing comes back as raw cron.> That is his answer to Q-119 - "describe
everything, marking the approximate ones as approximate" - and it replaced the
rule this function had followed since it was written. The old rule protected a
reader from a B<confident> sentence that is false; a sentence opening with
I<About> and naming what makes it inexact is not confident, so its premise is
gone rather than its reasoning being wrong.

B<The mark is for inexactness, not for complexity.> C<*/60> fires at minute 0
alone, so I<Every hour, on the hour> is exactly true and is said plainly - a
hedge there would spend the reader's attention on a doubt that does not exist.

B<The mark carries its reason.> I<About every 7 minutes> alone is a hedge;
C<(restarts each hour)> makes it an explanation, and a reader who needs the exact
firing times knows where the imprecision is.

B<The day-field OR is stated rather than marked>, which is the one place his
instruction is not followed literally. C<0 0 1 * 1> fires on the 1st I<and> on
every Monday - exactly, and surprisingly - so I<About> would describe the wrong
difficulty. It reads I<and also>, the one phrasing that cannot be read as an AND
of the two conditions. TKT-917.

C<job_schedule_words> takes a schedule and, optionally, a monitor's restart
interval. B<The second argument is optional and must stay so>: L<Tira::CLI::Browser>
called it with a schedule alone for three releases and F<t/517> asserts a dozen
cron phrasings through that form, so a required parameter would take the whole
schedule column with it.

A looping monitor reads as I<Runs continuously, restarting 5 seconds after it
ends> since 5.49. Before that the interval appeared on no card: C<restart_every>
occurred three times in the jobs view and all three were the editor or the save,
so a monitor that restarts itself and one that runs once were indistinguishable
on the board. It is added to the phrase rather than replacing it, because both
are true and the first matters more. TKT-915.

C<job_schedule_words> turns a stored schedule into a phrase - "Every 30 minutes",
"Every day at 09:00", "Runs continuously" for a monitor. TKT-884: the dashboard
card was the one place a schedule was visible and the one place it could not be
read.

B<In the engine rather than the browser, deliberately.> L<Tira::CLI::Browser>
already refuses to let the page interpret a schedule - the editor asks the engine
whether a crontab is valid instead of running a regex in JavaScript, because two
validators for one format is how the engine and the browser came to disagree
about attachment content types. A cron-to-English translator written in the page
would be a second reading of the same format, free to drift from the first in
exactly that way. The row carries the words; the page renders a string it is not
asked to understand.

B<And it refuses to guess.> Only shapes whose meaning is unambiguous from the
five fields are described. A step is one of the places that is easy to get
wrong: C<*/N> is "every N minutes" only when N divides the hour, because cron
restarts the step at the top of each hour - C<*/7> fires at 0, 7, ... 56 and then
at 0 again, a gap of four minutes rather than seven, and C<*/60> and above fire
at minute zero only. Those come back unchanged. Anything naming a day of the month or a month, and any
field it cannot read with certainty, is returned B<as itself>. A description that
is nearly right is worse than none: it would be read, believed, and the cron never
looked at again - which is the same failure the raw-cron card had, one layer along.

The words are an addition, never a substitution. A job is still stored as cron,
and the editor puts the real string back into the field when it opens.

=head1 A MONITOR CALLS IN - ITS LEAVINGS ARE NOT READ

TKT-851, from his instruction that monitors should not have separate logs and
his answer to Q-112 on 2026-09-03: "each output will be registered who talked to
the police".

A monitor never finishes, so its output cannot be handed over in one piece the
way a command-mode job's can. The first implementation gave it a per-job file
and had police follow that from a stored offset. It worked, and it was wrong
twice over: it kept the log he had said should not exist, and it made "this
monitor is alive and working" an inference from a file's contents rather than a
fact the monitor reported. A spool nobody has written to and a monitor that has
died look identical from outside.

So the monitor is started inside a pipeline and its output goes B<through>
C<skills/job/cli/feed>, which calls C<job_feed> to record what it said against
the job that said it, with C<last_output_at> as the moment it called in. That
timestamp is the fact a silence rule can be built on, and no file can provide
it.

A pipe is safe here for the one reason a pipe was rejected before: the feeder is
its reader and drains continuously, inside the same pipeline, so it cannot be
forgotten. An unread pipe fills at about 64KB and blocks the child forever.

Three things about the pair are easy to get wrong and are asserted in F<t/503>:

=over 4

=item * B<The buffer is bounded and says what it dropped.> The feeder writes
continuously and police may not read for thirty seconds, so the record needs its
own limit. What it could not keep is counted, because this epic exists precisely
because silence and nothing-to-say looked identical.

=item * B<The newest lines are the ones kept.> When a chatty poller overruns the
buffer, the oldest go - what a monitor is for is telling you what is true now.

=item * B<Draining nothing does not move the last-called-in time.> A monitor
that has not spoken must not look like one that has, or the silence rule is
built on a timestamp that police refreshes for it.

=back

C<job_output_drain> is called from L<Tira::CLI::Police> after the bridge write,
never from the pass: F<t/86> requires a police pass to change not one byte of
the board. It takes the count that was announced rather than whatever is in the
buffer when it runs, because the monitor may have called in during the gap and
taking those lines would discard output nobody ever saw.


=head2 The queue and the tail are different things

C<output> is a B<handover>. The feeder fills it, the police pass takes what it
announced, and it is meant to be emptied - that is what stops the bridge saying
the same thing twice. A caller reading it to find out what a monitor has been
saying finds nothing a second after it spoke.

So since 5.48 the record also carries C<recent>: a bounded tail of the monitor's
own words that the drain never touches. It exists for the dashboard, whose job
cards could not show a line of a monitor's output before it - the panel there was
filled only from the answer to a B<Run now> click, and a monitor's button is
B<Start>. TKT-922.

It holds one feeder delivery's worth, and that number is B<mirrored> from
C<$Tira::CLI::Job::BATCH_LINES> rather than referenced: this module does not
depend on the CLI, which is the same boundary that keeps it away from the process
table. F<t/532> asserts the two stay equal, which buys back what a shared
reference would have guaranteed without taking on the dependency.

Newest kept, oldest dropped, for the reason the queue does the same: a card shows
what is true now, and a tail that discarded the newest would show a monitor's
first minutes for ever.

=head1 CALL IT THROUGH TIRA

C<Tira> is the public entry point and keeps a forwarder for each verb here,
requiring this module at the call site. Every sub takes C<$self> - a blessed
C<Tira> - as its first argument.

=cut
