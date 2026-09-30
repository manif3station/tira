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

# Cron schedule parsing, validation and wording - _cron_field_values,
# _cron_parse, schedule_refusal, job_schedule_words and their shared data
# and helpers - is lifted into Tira::Job::Schedule (TKT-1044). Reached
# through a forward of the same name, required at the point of use: two
# existing callers already reach schedule_refusal and job_schedule_words by
# their fully-qualified Tira::Job:: name, and a forward preserves that.
#
# NO FORWARD FOR _cron_field_values, deliberately - unlike its three
# siblings, nothing calls it: not from outside this module by its
# fully-qualified name, and not from inside it either, since the only
# caller that ever did (_cron_parse) moved to Tira::Job::Schedule too and
# reaches its own copy directly. A stub with no caller is dead code the
# coverage gate would refuse - found running TKT-1063's own coverage check
# against a file this ticket did not otherwise touch.
sub _cron_parse {
    require Tira::Job::Schedule;
    return Tira::Job::Schedule::_cron_parse(@_);
}

sub schedule_refusal {
    require Tira::Job::Schedule;
    return Tira::Job::Schedule::schedule_refusal(@_);
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
            # last_run is NOT written here any more. TKT-942: it was assigned
            # undef at creation and never again, by anything, anywhere - a
            # field that looked like an answer and was only ever null, on
            # every job on every board. It is what the owner read as proof
            # his jobs were broken, three times in one afternoon, while they
            # were firing on schedule the whole time. Retired rather than
            # populated: what he wanted is last_due_at, joined on at read
            # from the ledger by job_list above, and a second field meaning
            # nearly the same thing is the drift this file keeps warning
            # about. Records written before this keep a stale last_run key;
            # nothing reads it, and no view ever rendered it.
            enabled => 1,
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

# TKT-942. C<last_due_at> is joined on HERE rather than stored, and only when
# the caller says which store to read. The instant lives in the police
# ledger because the rule that knows it must not write the record it judges -
# the constraint stated under "DUE TOLERATES A GAP BETWEEN CHECKS" below -
# and a field copied onto the record would be a second copy to keep in
# agreement with the first, which is how two validators for one format came
# to disagree on TKT-713.
#
# Every job gets the key, including one that has never been due, which then
# carries undef. That is deliberate: "never fired" and "fired, but nobody
# recorded it" were indistinguishable before this card - both simply absent -
# and telling them apart is the whole of what the owner was asking for.
# Monitor jobs are left alone; they are never "due" and already report
# themselves through last_output_at.
sub job_list {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $jobs = _job_read( $self, $root );

    if ( defined $args{store} && $args{store} ne '' ) {
        my $due = eval { $self->_violation_ledger( $args{store} )->{job_due_at} } || {};
        $_->{last_due_at} = $due->{ $_->{id} } for @{$jobs};
    }

    # TKT-984: --id was already reaching here - job.list's own CLI dispatch
    # builds %list = %{$args} before calling this - but nothing read it, so
    # the flag parsed cleanly and silently returned every job. Filtered here
    # rather than at the CLI, since Browser.pm and Board.pm call job_list
    # directly. _job_find is the same refusal job_update already uses for an
    # unknown id, so an id that names nothing is told so rather than answered
    # with an empty or a full list standing in for "not found".
    return [ _job_find( $jobs, $args{id} ) ]
      if defined $args{id} && $args{id} ne '';

    return $jobs;
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

# THE THIRD FACT A JOB CAN REPORT, and until TKT-963 the board could tell only
# two of them apart:
#
#   last_due_at     the window came round. Computed from the police ledger and
#                   never stored here, because the rule that knows the instant
#                   must not write the record it judges.
#   last_output_at  the job said something, stamped by job_feed above.
#   last_run_at     the command was run. This.
#
# HIS REPORT IS WHY IT EXISTS: tira.job.run answered ran=1 status=0 and left
# the record untouched, so the card went on reading "Never fired" - that line
# is painted from last_due_at, and a manual run never comes due. Writing
# last_due_at for it would claim the schedule fired when it did not.
#
# AND last_output_at CANNOT STAND IN, measured rather than argued: a job
# running /bin/true came back ran=1 status=0 and stamped nothing, because it
# said nothing. So a silent success and a window that merely came round were
# the same reading, on the scheduled path as well as the manual one.
#
# The retirement of last_run in this file's own POD does not forbid this. It
# was written when nothing ran commands, so due and ran were one event; since
# TKT-944 they are two, and TKT-950's could-not-start job is a third - due, and
# nothing executed.
sub job_ran {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "A job id is required\n" if !defined $args{id} || $args{id} eq '';

    return $self->_with_project_lock( $root, sub {
        my $jobs = _job_read( $self, $root );
        my $job  = _job_find( $jobs, $args{id} );

        $job->{last_run_at}  = $self->{clock}->();
        $job->{last_updated} = $self->{clock}->();
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

        # TKT-1063. A fresh start is a fresh chance, not a continuation of
        # whatever crash streak stopped the last one - a cap that survived a
        # deliberate restart would read as this run already having failed
        # before it ran at all.
        delete $job->{restart_cap_hit};
        delete $job->{restart_cap_hit_at};

        $self->_write_json( _job_path( $self, $root ), $jobs );
        return $job;
    } );
}

# TKT-1063. Written once, by the feeder itself, the moment restart_every's
# own crash-loop cap is reached - not by job.stop, which clears the pid but
# has no idea why the process it is signalling stopped restarting itself.
# monitor-dead reads this to say something more useful than a cold start:
# "not running" alone does not distinguish a monitor that never got going
# from one that tried and gave up a dozen times running.
sub job_restart_capped {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "A job id is required\n" if !defined $args{id} || $args{id} eq '';
    die "A count is required - how many consecutive crashes hit the cap\n"
      if !defined $args{count} || $args{count} !~ /\A[1-9][0-9]*\z/;

    return $self->_with_project_lock( $root, sub {
        my $jobs = _job_read( $self, $root );
        my $job  = _job_find( $jobs, $args{id} );
        die "Job $args{id} is not on this board\n" if !$job;

        $job->{restart_cap_hit}    = $args{count} + 0;
        $job->{restart_cap_hit_at} = $self->{clock}->();
        $job->{last_updated}       = $job->{restart_cap_hit_at};
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

sub job_schedule_words {
    require Tira::Job::Schedule;
    return Tira::Job::Schedule::job_schedule_words(@_);
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

# A minute-by-minute scan of a gap this large would cost real time on every
# pass for a job an agent simply has not touched in a while, and an
# unattended caller has no one watching to notice a slow pass. Past this many
# minutes, $since is treated as absent - exact-minute matching only - the
# same as a job's first-ever check. TKT-935.
use constant _JOB_DUE_GAP_CAP_MINUTES => 10080;    # one week

# Is this job due at this instant, or (TKT-935) at any minute since $since?
# The instant is ALWAYS an argument - never the wall clock - so an assertion
# is about the schedule rather than about when the suite happened to run,
# the same reason every other dated behaviour in this engine takes an
# injected clock.
#
# $since IS OPTIONAL, and its absence means exactly what it always meant:
# only $when's own minute counts. Michael's decision (Q-124, TKT-935) was
# that job_is_due should tolerate a gap between checks - the only caller
# this board ever had running was irregular (an agent's own commands, not an
# independent per-minute tick), so an exact-minute match missed almost every
# due window. Given $since, every minute from one past it through $when is
# checked, and the first match found makes the job due - it does not matter
# which one, only that at least one did, because the rule that calls this
# reports the CURRENT instant as the window regardless (unchanged from
# before this card).
#
# NOT APPLIED BACKWARDS, the same reasoning unproven() already gives for
# cards that shipped before it existed: a job with no $since (its first-ever
# check, including every job that already existed before this shipped) is
# exact-minute only, so upgrading does not flood the bridge with every hour
# a stale job silently missed.
sub job_is_due {
    my ( $self, $job, $when, $since ) = @_;
    return 0 if !$job;
    return 0 if exists $job->{enabled} && !$job->{enabled};

    # A monitor runs continuously rather than on a tick, so it is never
    # "due" - asking is a category error, and answering yes would make the
    # police start it once a minute.
    my $schedule = $job->{schedule} // '';
    return 0 if $schedule eq 'monitor';

    my $sets = eval { _cron_parse($schedule) } or return 0;

    my $when_epoch = _epoch_of_minute($when);

    my $since_epoch;
    if ( defined $since && $since ne '' ) {
        $since_epoch = _epoch_of_minute($since);
        undef $since_epoch
          if $when_epoch - $since_epoch > _JOB_DUE_GAP_CAP_MINUTES * 60;
    }

    # $since at or past $when means nothing has actually elapsed since the
    # last check - two passes run back to back with the clock unmoved, which
    # a fixture that checks every rule fires does deliberately. There is no
    # gap to fill, so this collapses to the plain exact-minute check rather
    # than an empty range that would report a schedule as not due at the
    # exact instant it is.
    my $start_epoch = defined $since_epoch && $since_epoch < $when_epoch
      ? $since_epoch + 60
      : $when_epoch;
    for ( my $epoch = $start_epoch; $epoch <= $when_epoch; $epoch += 60 ) {
        return 1 if _cron_minute_matches( $sets, $epoch, $schedule );
    }
    return 0;
}

# A timestamp truncated to the minute, as seconds since the epoch - the unit
# every comparison and every step of the gap scan above works in, so DST and
# month-length are POSIX::mktime's problem rather than this file's.
sub _epoch_of_minute {
    my ($when) = @_;
    my ( $year, $month, $day, $hour, $minute ) =
      $when =~ /\A(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/
      or die "Cannot read the time '$when'\n";
    return POSIX::mktime( 0, $minute, $hour, $day, $month - 1, $year - 1900 );
}

# Whether one specific minute (as an epoch) matches a job's parsed cron sets.
# Split out of job_is_due so the gap scan and the exact-minute case (the
# scan's own one-iteration special case, given no $since) share one reading
# of what "matches" means - two copies of a five-field comparison is exactly
# how two of them would eventually disagree.
sub _cron_minute_matches {
    require Tira::Job::Schedule;
    return Tira::Job::Schedule::_cron_minute_matches(@_);
}

1;
