package Tira::CLI::Browser::Jobs;

# The job-provider block, lifted out of Tira::CLI::Browser's own providers()
# so a 500+ line file stays a file somebody can read - TKT-1042, mirroring
# how TKT-1041 lifted the move-path guards out of Tira::CLI.pm the same day.
#
# ONE FUNCTION, NOT SEVEN. providers() builds $tira/$project/$json once and
# every job route closes over them; splitting that into seven exported subs
# each needing the same three arguments would not simplify anything, so this
# keeps the closures and returns the same key => sub {...} pairs providers()
# already spliced inline, just from one call instead of typed in place.
#
# CALLED, NOT REQUIRED-AND-FORWARDED: unlike Tira::CLI::Move's one-line
# forwards (which preserve unqualified calls from elsewhere in the same
# package), nothing outside Tira::CLI::Browser ever called these closures by
# name - they only ever existed as anonymous values in one hash literal - so
# there is no existing caller to preserve compatibility with. providers()
# just requires this module and calls job_providers() where the block used
# to sit.

use strict;
use warnings;

use Tira;

sub job_providers {
    my ( $tira, $project, $json ) = @_;
    return (
        # Repeated jobs, read-only here. Every job the board holds, so the
        # page can show the whole schedule at a glance rather than sending
        # somebody to .tira/jobs.json - which is the same "nobody can see it"
        # problem EPC-014 started from. Running one from the page and editing
        # one are TKT-843; this provider only reads. TKT-839.
        # TKT-861. The section listed a monitor and said nothing about whether
        # it was up, so one that died an hour ago looked like one polling
        # happily - the gap EPC-014 was filed for, one layer up: monitor-dead
        # announces a stopped monitor on the bridge while the board he actually
        # watches stays silent.
        #
        # THE VERDICT IS NOT DECIDED HERE. job_monitor_alive is the same call
        # monitor-dead makes, so the page and the bridge cannot answer one
        # question differently in front of him. A liveness check written for the
        # browser is the fault TKT-860 had to unpick.
        #
        # THE PROCESS TABLE IS READ ONCE, not once per monitor: it is the
        # expensive half, and this route is polled every thirty seconds. Read
        # lazily, so a board with no live monitors to judge does not pay for it
        # at all.
        #
        # SILENT FOR A CRON JOB AND A DISABLED MONITOR, both absent on purpose -
        # the stance monitor-dead already takes. A row reading "not running"
        # against every cron job is a false alarm by design, and an indicator
        # that cries wolf is one he stops reading, which is the failure this is
        # meant to end.
        jobs => sub {
            # TKT-942: with the store, each job carries last_due_at - when
            # it was genuinely last due - so a cron job of either mode can
            # say it is alive instead of showing the blank the owner kept
            # reading as broken.
            my $jobs = $tira->job_list(
                project => $project,
                store   => scalar eval {
                    require Tira::CLI::Police;
                    Tira::CLI::Police::_police_store(
                        $tira->discover_project( project => $project ) );
                },
            );
            my $processes;
            my $processes_attempted;
            my @rows;
            for my $job ( @{$jobs} ) {
                my %row = %{$job};

                # SCRUBBED BEFORE IT IS DECIDED. Raised in review: the copy
                # takes every stored field, so a record that already carried a
                # running key - a hand-edited file, an import, a later engine
                # change - would arrive at the page with one even on a cron row,
                # and render "Not running" against a job that is not supposed to
                # be up. That is the false alarm this whole field is arranged to
                # avoid, delivered by the one path that does not check.
                #
                # The same lesson as TKT-859's message-mode monitor: a
                # constraint the engine enforces on WRITE is not a guarantee at
                # READ, so the read decides for itself.
                delete $row{running};

                # The words the card face shows. Added rather than substituted:
                # it is still STORED as cron, which is his own requirement, and
                # the editor puts the real string back into the field when it
                # opens. TKT-884, inside TKT-892.
                require Tira::Job;
                $row{schedule_words} =
                  Tira::Job::job_schedule_words( $job->{schedule},
                      $job->{restart_every} );

                if ( ( $job->{schedule_kind} // '' ) eq 'monitor' && $job->{enabled} ) {
                    require Tira::CLI::Job;
                    require Tira::Job;

                    # A COSMETIC FIELD MUST NOT TAKE DOWN THE ROUTE IT RIDES ON,
                    # also from review. This is polled every thirty seconds; one
                    # transient failure reading the process table would turn the
                    # whole jobs list into an error page, and the list is the
                    # part somebody needs. So the read is attempted once, and if
                    # it fails the liveness is simply absent - the page then
                    # shows the row with no indicator, which is what it already
                    # does for a cron job and reads as "not known" rather than
                    # as "not running".
                    #
                    # TKT-960: the old `// []` erased the one distinction that
                    # matters here, the same erasure TKT-949 fixed on the
                    # bridge. An empty list has two causes that mean opposite
                    # things - the read failed, or every monitor is genuinely
                    # down - and both used to read as "not known". $processes
                    # now stays undef on a failed read (still "not known",
                    # still no indicator) and becomes a real, possibly-empty
                    # arrayref on a successful one - which is a known answer
                    # even when it is empty, so the guard below checks
                    # definedness rather than truthiness.
                    if ( !$processes_attempted ) {
                        $processes_attempted = 1;
                        $processes = eval { Tira::CLI::Job::_running_processes_for_jobs() };
                    }

                    $row{running} =
                      Tira::Job::job_monitor_alive( $job, $processes )
                      ? Cpanel::JSON::XS::true
                      : Cpanel::JSON::XS::false
                      if defined $processes;
                }
                push @rows, \%row;
            }
            return $json->encode( \@rows );
        },

        # The play button. Runs one job now whatever its schedule says, and a
        # MONITOR row starts rather than fires - a monitor has no schedule to
        # bypass, so "run it now" there means start it. Both go through
        # Tira::CLI::Job::run_now, which is TKT-841's executor with the
        # due-check not asked, rather than a second way to run a command.
        # EPC-014, TKT-843.
        job_run => sub {
            my ($payload) = @_;
            die "A job id is required\n"
              if !defined $payload->{id} || $payload->{id} eq '';
            require Tira::CLI::Job;
            return $json->encode(
                Tira::CLI::Job::run_now( $tira, { project => $project, id => $payload->{id} } ) );
        },

        # Saving the modal. The engine validates again on write - this is not
        # trusting the browser check above, it is the same rule asked twice
        # because the browser one is advice to a person and this one is the
        # record refusing. A save that got past a stale page still cannot
        # store a broken schedule.
        # One route, two verbs, chosen by whether the payload names a job.
        #
        # TKT-858. Until then this died without an id and only ever updated, so
        # a job could be run, edited and listed from the page and created only
        # from a terminal - which stopped being a curiosity the afternoon the
        # five standing monitors moved onto board-owned jobs and this section
        # became where he watches them.
        #
        # DISPATCHING HERE RATHER THAN ADDING A job_create PROVIDER: the page
        # already posts to /jobs/save, and every entry in @PROVIDERS is a
        # breaking change to every hand-built caller of build_psgi_app in the
        # suite. One payload shape, one route, one place the refusals live.
        #
        # THE REFUSALS ARE NOT REWRITTEN. job_add calls _job_fields, which owns
        # the schedule requirement and the refusal of a message-mode monitor
        # (TKT-842 - a monitor with no command can never be found alive in the
        # process table, so it would be reported dead forever). The create path
        # inherits both by calling the engine rather than checking for itself.
        # A second copy of those rules is the fault this section already
        # declined to grow on TKT-843, and the one that made the engine and the
        # browser disagree about attachment content types on TKT-713.
        job_save => sub {
            my ($payload) = @_;
            # EVERY FIELD A JOB HAS, not the three it had when this was written.
            # expect_every (TKT-863) and restart_every (TKT-891) both landed
            # after TKT-858 built this, and neither was added here - so the page
            # could offer a control whose value the save silently discarded,
            # which is worse than not offering it: the form would report success
            # and the board would hold something else. TKT-892.
            #
            # Still `defined` rather than truthy, for the reason the engine
            # cares about: an UNDECLARED expectation is not a zero. Omitting the
            # key leaves the job's value alone; sending it sets it. A truthy test
            # would make 0 unsendable, and 0 is exactly what the engine refuses
            # and must be allowed to refuse rather than have swallowed here.
            my %given = (
                ( defined $payload->{schedule} ? ( schedule => $payload->{schedule} ) : () ),
                ( defined $payload->{command}  ? ( command  => $payload->{command} )  : () ),
                ( defined $payload->{message}  ? ( message  => $payload->{message} )  : () ),
                # EXISTS, NOT DEFINED, AND ONLY FOR THESE TWO. The engine
                # reads these with `exists` (Tira::Job job_update), so an
                # explicit undef CLEARS the field while an absent key leaves it
                # alone. A `defined` test here collapses those two into one and
                # loses the clearing half: unticking the looping box or emptying
                # the expectation would send nothing, the engine would leave the
                # old value, and the form would report success over a job it had
                # not changed.
                #
                # Measured before it was fixed - a job with restart_every 5 and
                # expect_every 7, saved with the box unticked and the field
                # blank, came back holding 5 and 7. The form could set these and
                # never unset them.
                #
                # The other three keep `defined` deliberately: a job must always
                # have a schedule, and clearing a command or a message is not a
                # thing the engine offers - it refuses a job with neither.
                ( exists $payload->{expect_every}
                    ? ( expect_every => $payload->{expect_every} ) : () ),
                ( exists $payload->{restart_every}
                    ? ( restart_every => $payload->{restart_every} ) : () ),
            );

            if ( !defined $payload->{id} || $payload->{id} eq '' ) {
                my $made = $tira->job_add( project => $project, %given );

                # A MONITOR IS STARTED ON CREATION. His answer to Q-109 on
                # TKT-858: "Create it and start it, for monitor-kind only. The
                # page then does what somebody adding a monitor obviously
                # meant, at the cost of a save that launches a process."
                #
                # My own default had been the other way - create it stopped and
                # say so - so this is his call, not a fallback. The cost he
                # accepted is real: saving a form spawns a process. What it buys
                # is that a monitor created here is not immediately reported dead
                # by monitor-dead, which is the confusing state the key detail on
                # that card warned about.
                #
                # run_now rather than a spawn written here: it is the same
                # executor the play button uses, and it carries the
                # already-running refusal and the spawn/record atomicity fix
                # that only came out of review. Cron jobs are untouched - they
                # have nothing to start.
                if ( ( $made->{schedule_kind} // '' ) eq 'monitor' ) {
                    require Tira::CLI::Job;

                    # THE JOB IS ALREADY WRITTEN BY HERE, so a start that fails
                    # must not read as a create that failed. Raised in review:
                    # letting run_now's die escape would answer the page with an
                    # error over a job that exists, and the obvious response to
                    # that is to press Add again - which creates a second one.
                    # So the refusal names what actually happened and what to do
                    # about it, rather than pretending nothing was written.
                    my $started = eval {
                        Tira::CLI::Job::run_now( $tira,
                            { project => $project, id => $made->{id} } );
                        1;
                    };
                    if ( !$started ) {
                        my $why = $@ || 'it could not be started';
                        $why =~ s/\s+\z//;
                        die "Job $made->{id} was created but not started: $why. "
                          . "It exists on the board - start it with "
                          . "tira.job.start --id $made->{id} rather than adding it again.\n";
                    }

                    # Read back so the page is told the pid and started_at the
                    # start actually recorded, rather than the pre-start record
                    # job_add returned.
                    #
                    # Falling back to the pre-start record rather than letting a
                    # miss become undef: also from review. A grep that finds
                    # nothing would encode JSON null, and the page would report
                    # "no job" about a job that had just been created AND
                    # started - the most misleading answer available.
                    my ($fresh) = grep { $_->{id} eq $made->{id} }
                      @{ $tira->job_list( project => $project ) };
                    $made = $fresh if $fresh;
                }

                return $json->encode($made);
            }

            return $json->encode( $tira->job_update(
                project => $project,
                id      => $payload->{id},
                %given,
                ( defined $payload->{enabled}  ? ( enabled  => $payload->{enabled} )  : () ),
            ) );
        },

        # HIS COMPLAINT 1 OF 2026-09-03: "In the UI there is no way i can delete
        # any existing job card". The verb has always existed; the surface never
        # did. TKT-892, absorbing TKT-889.
        #
        # THE REFUSAL IS THE POINT, not an edge case. tira.job.delete refuses a
        # RUNNING monitor and names tira.job.stop in doing so (TKT-893), because
        # deleting the record while the process runs leaves a pid nothing on the
        # board points at - the orphan TKT-869 is about. That die travels to the
        # page as the engine's own words, the same way a save refusal already
        # does, rather than being caught and softened into "could not delete".
        # A person told WHY can act; a person told THAT cannot.
        job_delete => sub {
            my ($payload) = @_;
            die "A job id is required\n"
              if !defined $payload->{id} || $payload->{id} eq '';
            return $json->encode(
                $tira->job_delete( project => $project, id => $payload->{id} ) );
        },

        # TKT-883's buttons, absorbed here: a running monitor offers Stop, a
        # stopped one offers Start. Both verbs exist - job.stop is new from
        # TKT-893, and it is what unblocked this card, since a Stop button that
        # can only refuse is worse than no button at all.
        #
        # THROUGH THE CLI DISPATCHER, NOT THE ENGINE SUB. Tira::CLI::Job owns the
        # half that touches the process: the engine clears the record and the CLI
        # signals, in that order, so a stop that races a dying process still
        # leaves the board honest. Calling $tira->job_stop from here would clear
        # the record and signal nothing, which is the exact state - board says
        # stopped, process still running - this card exists to stop happening.
        job_stop => sub {
            my ($payload) = @_;
            die "A job id is required\n"
              if !defined $payload->{id} || $payload->{id} eq '';
            require Tira::CLI::Job;
            return $json->encode(
                Tira::CLI::Job::dispatch( $tira,
                    { project => $project, id => $payload->{id} }, {}, 'job.stop' ) );
        },

        # And the other half of the pair. run_now rather than a spawn written
        # here, for the reason the create path already gives: it is the same
        # executor the play button uses, and it carries the already-running
        # refusal and the spawn/record atomicity fix that only came out of
        # review. A monitor has no schedule to bypass, so starting it and
        # running it now are the same act.
        job_start => sub {
            my ($payload) = @_;
            die "A job id is required\n"
              if !defined $payload->{id} || $payload->{id} eq '';
            require Tira::CLI::Job;
            return $json->encode(
                Tira::CLI::Job::run_now( $tira,
                    { project => $project, id => $payload->{id} } ) );
        },

        # What the modal shows while somebody types. The answer is the ENGINE's
        # own refusal, not a regex written again in JavaScript - the browser
        # asks rather than decides, so the two cannot drift apart and accept
        # something the save would then reject.
        job_check => sub {
            my ($payload) = @_;
            require Tira::Job;
            my $refusal = Tira::Job::schedule_refusal( $payload->{schedule} );
            return $json->encode( {
                ok      => $refusal ? Cpanel::JSON::XS::false : Cpanel::JSON::XS::true,
                refusal => $refusal,
            } );
        },
    );
}

=head1 NAME

Tira::CLI::Browser::Jobs - the browser's job-management routes

=head1 DESCRIPTION

Seven routes lifted out of C<Tira::CLI::Browser>'s own C<providers()> -
listing repeated jobs with their live monitor status, running one now,
saving/creating from the editor, deleting, and the play/stop/schedule-check
actions - all closing over the same C<$tira>/C<$project>/C<$json> that
C<providers()> already builds once.

=head1 SEE ALSO

L<Tira::CLI::Browser>

=cut

1;
