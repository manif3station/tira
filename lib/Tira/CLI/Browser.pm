package Tira::CLI::Browser;

# The coderefs the browser dashboard is built from, moved out of Tira::CLI so
# that reading the CLI to change one command no longer means reading these too.
#
# This is 702 lines needed by exactly one invocation - the one that serves a
# board - and Tira::CLI loads it with require at that point rather than with use
# at the top, the same way it already treats Tira::DashboardWeb and
# Tira::OnboardWeb. A CLI call that never serves a board never compiles any of
# it.
#
# THE ENTRY POINT KEEPS ITS OLD NAME. Tira::CLI::browser_providers still exists
# and still answers; it forwards here. Twenty test files and the dashboard call
# it by that name, and a refactor that renames its own front door is not
# behaviour-preserving. Tira::CLI is the index: it says the thing exists and
# where it lives.
#
# The six helpers this needs are called as Tira::CLI::_name(), qualified rather
# than imported. Nothing loads this module except Tira::CLI, so Tira::CLI is
# always already in memory when these run - and writing the package name at the
# call site says where the helper lives, which is the whole point of splitting
# the file.

use strict;
use warnings;

use Cpanel::JSON::XS ();
use File::Temp ();
use Tira;
# Tira::CLI is always in memory when this runs - nothing loads this module
# except Tira::CLI itself - but the helpers below are called by their full
# names, and an assumption a reader has to reconstruct is not a dependency.
# The require is free (%INC already holds it) and it is what makes
# `perl -c` on this file alone meaningful. TKT-607.
use Tira::CLI ();

sub providers {
    require Tira::CLI::Police;
    my (%args) = @_;
    my $tira = $args{tira};
    my $project = $args{project};
    my $json = Tira::json_object()->canonical;
    my %editable = map { $_ => 1 } qw(
        title description problem_or_feature solution_needed source
        sdlc_gate lifecycle fix_version assignee reporter priority
        start_date due_date
    );
    my %list_editable = (
        labels => 'labels_replace', affects_versions => 'affects_versions_replace',
        key_details => 'key_details_replace', deliverables => 'deliverables_replace',
        acceptance_criteria => 'acceptance_replace', test_steps => 'test_steps_replace',
        bdd => 'bdd_replace', atdd => 'atdd_replace',
        scope_included => 'scope', scope_excluded => 'scope',
    );
    return (
        move => sub {
            my ($payload) = @_;
            die "Move payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref column)) {
                die "Move payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my %move_args = (
                project => $project,
                ( defined $payload->{type} ? ( type => $payload->{type} ) : () ),
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
                ref => $payload->{ref}, column => $payload->{column},
            );

            # The gating half of TKT-426 stays CLI/agent-only on purpose - a
            # human moving a card in the browser is not an agent skipping a
            # gate. But the bookkeeping half (populating a destination
            # column's required-action template, resetting one on the way
            # back through) is not enforcement, it is keeping the card
            # accurate for whoever looks at it next - and that has to happen
            # here too, or a browser move silently leaves required_items
            # stale in either direction. TKT-452.
            my $before = eval { $tira->record_show(%move_args) };
            my $from   = $before ? $before->{column} : undef;
            my $record = $tira->record_move(%move_args);

            # column_list (and the required-action bookkeeping below) needs a
            # concrete board type, unlike record_show/record_move above, which
            # resolve the record by ref alone (TKT-532) - recovered here from
            # the record record_move already loaded, so a caller is never
            # required to say what the engine can already tell for itself.
            my %column_args = ( %move_args, type => $record->{type} );
            my $columns = eval { $tira->column_list(%column_args) };
            Tira::CLI::_apply_column_required_actions( $tira, \%column_args, $from, $payload->{column}, $columns, $record )
              if ref $columns eq 'ARRAY';

            # The destination's ENTRY actions land here too, for the same
            # reason its exit ones do: bookkeeping, not gating. The refusal
            # stays CLI-only (TKT-426), so a dragged card is admitted - but it
            # arrives carrying what that column asks of it rather than
            # pretending nothing was asked. TKT-591.
            # The failure is SAID rather than dropped. This path cannot
            # refuse - that is TKT-426's whole point - but it can decline to
            # be silent: a column whose entry list could not be placed leaves
            # the card claiming nothing was asked of it, and the server log is
            # where whoever is running the dashboard would find out. Codex
            # review caught the POD promising a report that nothing made.
            my $entry_failed = ref $columns eq 'ARRAY'
              ? Tira::CLI::_populate_entry_required_actions( $tira, \%column_args, $payload->{column}, $columns, $record )
              : [];
            printf {*STDERR} "%s moved into %s, but %d of that column's entry required action(s) could not be put on the card: %s\n",
              $payload->{ref}, $payload->{column}, scalar @{$entry_failed},
              join( '; ', map { ( length $_->[0] ? $_->[0] : '(an empty entry action)' ) . " - $_->[1]" } @{$entry_failed} )
              if @{$entry_failed};

            # Bookkeeping, so it belongs here as well as on the CLI path -
            # TKT-452's distinction exactly: the gating half stays CLI-only
            # because a human dragging a card is not an agent skipping a gate,
            # but keeping the card accurate for whoever looks at it next is
            # not enforcement and has to happen either way. Left out at first,
            # which meant a card dragged back to backlog in the browser went
            # on claiming somebody was working its tasks - the very fault
            # TKT-596 exists to fix, surviving on the other path. TKT-596.
            Tira::CLI::_reset_linked_tasks_on_return( $tira, \%column_args, $payload->{column} );

            $record = $tira->record_show(%column_args) if ref $columns eq 'ARRAY';

            return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
        },
        detail => sub {
            my ($payload) = @_;
            die "Record detail requires ref\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref};
            my $record = $tira->record_show(
                project => $project,
                ( defined $payload->{type} ? ( type => $payload->{type} ) : () ),
                ref => $payload->{ref},
            );
            Tira::CLI::_stamp_attachment_types( $tira, $project, $payload->{ref}, $record );

            # What is owed in the column this card is actually sitting in,
            # decided HERE rather than in the dialog. The dialog renders one
            # group per column and a card with a dozen columns of history gets a
            # dozen headings, exactly one of which is the work in front of you.
            #
            # It travels in the record rather than through a fetch of its own
            # because the dialog already has the record, and it is computed by
            # _unmet_in_column rather than by a filter in JavaScript because
            # that sub is what tira.required-action.list --blocking answers
            # with. A predicate written again in JS would be a second opinion
            # about what "done" means - which is exactly the drift TKT-657
            # fixed when four readers of the same status disagreed about case.
            # TKT-665.
            my $unmet = Tira::CLI::_unmet_in_column( $record, $record->{column} );
            $record->{unmet_in_column} = {
                column => $record->{column},
                count  => scalar @{$unmet},
                items  => [ map { $_->{id} } @{$unmet} ],
            };
            return $json->encode($record);
        },
        # The browser goes through the same subroutines the command line goes
        # through, so a rule cannot be enforced in one and forgotten in the
        # other. A failed sign-in answers ok => false rather than dying,
        # because the login page has to show a message, not a stack trace.
        # Fetched only when somebody expands the section. A card has a great
        # deal happen to it, and loading all of it whenever a card is opened
        # would bury everything else on the card.
        work_log => sub {
            my ($payload) = @_;
            die "A card reference is required\n" if !defined $payload->{ref};
            return $json->encode(
                $tira->work_log( project => $project, ref => $payload->{ref} ) );
        },

        # What police has said about this card, read when the card opens rather
        # than when a section is expanded: there is at most one line per thing
        # police has said, unlike the work log, and the section has to know
        # whether it has anything before it decides to appear at all.
        #
        # A card reference is required. Answering an unnamed card with the whole
        # board's enforcement log would put every other card's chasing on
        # whichever card happened to be open.
        # What is owed in the column the card is sitting in, as opposed to the
        # card-wide count the dialog's heading shows. A card with a dozen
        # columns of history renders a dozen groups, exactly one of which is
        # the work in front of you, and nothing marked it.
        #
        # IT RETURNS Tira::CLI::_unmet_in_column'S SELECTION AND NOTHING ELSE.
        # That sub is what tira.required-action.list --blocking already answers
        # with - this column, minus exemptions, minus anything already done -
        # and the card asking for this required the dialog's number to match
        # --blocking. Two selections cannot be held to that; one selection
        # served two ways can, which is why this is a provider rather than a
        # filter written again in JavaScript. TKT-665.
        unmet_in_column => sub {
            my ($payload) = @_;
            die "A card reference is required\n" if !defined $payload->{ref};
            my $record = $tira->record_show( project => $project, ref => $payload->{ref} );
            my $unmet = Tira::CLI::_unmet_in_column( $record, $record->{column} );
            return $json->encode( {
                column => $record->{column},
                count  => scalar @{$unmet},
                items  => $unmet,
            } );
        },
        police_log => sub {
            my ($payload) = @_;
            die "A card reference is required\n" if !defined $payload->{ref};
            return $json->encode(
                $tira->enforcement_log(
                    project => $project,
                    store   => $args{store}
                      // Tira::CLI::Police::_police_store( $tira->discover_project( project => $project ) ),
                    ref     => $payload->{ref},
                ) );
        },
        login_page => sub {
            my $project_name = eval { $tira->project_show( project => $project )->{name} };
            return $tira->login_page_html( name => $project_name );
        },
        login_start => sub {
            my ($payload) = @_;
            my $token = eval {
                $tira->login_start(
                    project => $project, id => $payload->{id},
                    password => $payload->{password},
                );
            };
            return $json->encode( { ok => Cpanel::JSON::XS::false } ) if !defined $token;
            return $json->encode( { ok => Cpanel::JSON::XS::true, token => $token } );
        },
        login_register => sub {
            my ($payload) = @_;
            my $person = eval {
                $tira->login_register(
                    project => $project, id => $payload->{id},
                    password => $payload->{password},
                );
            };
            return $json->encode( { ok => Cpanel::JSON::XS::false } ) if !$person;
            my $token = $tira->login_start(
                project => $project, id => $payload->{id}, password => $payload->{password} );
            return $json->encode( { ok => Cpanel::JSON::XS::true, token => $token, claimed => Cpanel::JSON::XS::true } );
        },
        session_resume => sub {
            my ($payload) = @_;
            my $session = $tira->session_resume( project => $project, token => $payload->{token} );
            return $json->encode( $session ? { %{$session} } : { person => undef } );
        },
        session_peek => sub {
            my ($payload) = @_;
            my $session = $tira->session_peek( project => $project, token => $payload->{token} );
            return $json->encode( $session ? { %{$session} } : { person => undef } );
        },
        session_end => sub {
            my ($payload) = @_;
            my $ended = eval { $tira->session_end( project => $project, token => $payload->{token} ) };
            return $json->encode( { ok => $ended ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false } );
        },
        question_answer => sub {
            my ($payload) = @_;
            die "Answering needs a question and some text\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id} || !defined $payload->{text};
            return $json->encode( {
                ok => Cpanel::JSON::XS::true,
                question => $tira->question_answer(
                    project => $project, id => $payload->{id},
                    text => $payload->{text}, author => $payload->{author},
                ),
            } );
        },
        question_attach => sub {
            my ($payload) = @_;
            die "Attaching needs a question, a filename and content\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id}
              || !defined $payload->{filename} || !defined $payload->{content_base64};
            require MIME::Base64;
            my $content = MIME::Base64::decode_base64( $payload->{content_base64} );
            die "That upload is empty\n" if !length $content;

            # The browser hands over bytes rather than a path, so they are
            # written somewhere the engine can take a path to and then removed.
            require File::Temp;
            my ( $fh, $path ) = File::Temp::tempfile(
                SUFFIX => ( $payload->{filename} =~ /(\.[A-Za-z0-9]+)\z/ ? $1 : '.bin' ) );
            binmode $fh;
            print {$fh} $content;
            close $fh;
            my $question = eval {
                $tira->question_attach(
                    project => $project, id => $payload->{id},
                    file => $path, to => $payload->{to},
                    filename => $payload->{filename} );
            };
            my $error = $@;
            unlink $path;
            die $error if !$question;
            return $json->encode( { ok => Cpanel::JSON::XS::true, question => $question } );
        },
        question_mark => sub {
            my ($payload) = @_;
            die "Marking needs a question and a mark\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id} || !defined $payload->{mark};
            return $json->encode( {
                ok => Cpanel::JSON::XS::true,
                question => $tira->question_mark(
                    project => $project, id => $payload->{id}, mark => $payload->{mark} ),
            } );
        },
        columns => sub {
            my ($query) = @_;
            my $list = $tira->column_list( project => $project, type => $query->{type} );

            # Which columns already start new cards, so the dialog's own
            # checkbox opens showing what tira.column.roles --role entry=X
            # already declared, rather than always opening blank. TKT-494.
            my $declared = eval { $tira->column_roles( project => $project, type => $query->{type} )->{entry} };
            my @entries = ref $declared eq 'ARRAY' ? @{$declared}
              : ( defined $declared && $declared ne '' ? ($declared) : () );
            my %is_entry = map { $_ => 1 } @entries;
            $_->{entry} = $is_entry{ $_->{name} } ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false
              for @{$list};
            return $json->encode($list);
        },
        column_apply => sub {
            my ($payload) = @_;
            die "Column layout must be an object with a type and columns\n"
              if ref($payload) ne 'HASH' || ref $payload->{columns} ne 'ARRAY';
            my $result = $tira->column_apply(
                project => $project, type => $payload->{type},
                columns => $payload->{columns},
            );

            # An 'entry' field is which columns the dialog's own checkboxes
            # left checked - a full replacement of the entry role, the same
            # semantics tira.column.roles --role entry=X already has, not an
            # add-only merge. Omitted entirely (not an empty array) means the
            # save was only ever about layout, so the existing entry columns
            # are left exactly as they were. TKT-494.
            if ( exists $payload->{entry} && ref $payload->{entry} eq 'ARRAY' ) {
                $tira->column_roles_set(
                    project => $project, type => $payload->{type},
                    roles   => { entry => $payload->{entry} },
                );
            }
            return $json->encode($result);
        },
        # The board-wide police policy engine, separate from a column's own
        # required-action template (the columns/column_apply pair above): 36
        # rules covering things a column dialog cannot express at all -
        # conversation-not-folded, question-unanswered, card-stalled and the
        # rest. Requested directly: "create a new modal on the html
        # dashboard, the user can view and edit and add the policies not
        # just column policies." TKT-493.
        policies => sub {
            return $json->encode( {
                declared     => $tira->policy_list( project => $project ),
                declined     => $tira->policy_declined( project => $project ),
                undeclared   => $tira->policy_undeclared( project => $project ),
                rules        => $tira->policy_rule_specs(),
                actions      => $tira->policy_actions(),
                token_fields => $tira->policy_message_fields(),
                token_help   => $tira->policy_message_field_help(),
            } );
        },
        policy_add => sub {
            my ($payload) = @_;
            die "Policy payload must be an object\n" if ref($payload) ne 'HASH';

            # Every field policy.add itself accepts, so nothing typeable on
            # the command line is unreachable from the dashboard - the same
            # completeness bar TKT-493's own acceptance criteria set.
            my %policy = map { $_ => $payload->{$_} }
              grep { defined $payload->{$_} && $payload->{$_} ne '' }
              qw(rule action enter before column age read_age max pattern
                 message require sandbox require_link link_to
                 type on_column ref);
            return $json->encode(
                $tira->policy_add( project => $project, %policy ) );
        },
        policy_remove => sub {
            my ($payload) = @_;
            die "A policy id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            return $json->encode(
                $tira->policy_remove( project => $project, id => $payload->{id} ) );
        },
        policy_decline => sub {
            my ($payload) = @_;
            die "A policy rule is required\n" if !defined $payload->{rule} || $payload->{rule} eq '';
            return $json->encode(
                $tira->policy_decline(
                    project => $project, rule => $payload->{rule}, reason => $payload->{reason},
                    ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
                ) );
        },

        # TKT-516: the Task List section's own providers, one per CLI verb -
        # full parity, his words, so every one of these exists even where a
        # thin dashboard control is all it needs.
        tasklist => sub {
            my ($query) = @_;
            return $json->encode(
                $tira->tasklist_list( project => $project, session => $query->{session} // '' ) );
        },

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
            my $jobs = $tira->job_list( project => $project );
            my $processes;
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
                  Tira::Job::job_schedule_words( $job->{schedule} );

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
                    $processes //= eval { Tira::CLI::Job::_running_processes_for_jobs() } // [];

                    $row{running} =
                      Tira::Job::job_monitor_alive( $job, $processes )
                      ? Cpanel::JSON::XS::true
                      : Cpanel::JSON::XS::false
                      if @{$processes};
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
                ( defined $payload->{expect_every}
                    ? ( expect_every => $payload->{expect_every} ) : () ),
                ( defined $payload->{restart_every}
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
        tasklist_add => sub {
            my ($payload) = @_;
            die "Task text is required\n" if !defined $payload->{text} || $payload->{text} eq '';
            return $json->encode( $tira->tasklist_add(
                project => $project, text => $payload->{text}, session => $payload->{session} // '',
                refs => $payload->{refs} // [],
            ) );
        },
        tasklist_update => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            return $json->encode( $tira->tasklist_update(
                project => $project, id => $payload->{id}, status => $payload->{status},
                text => $payload->{text}, session => $payload->{session} // '' ) );
        },
        tasklist_next => sub {
            my ($payload) = @_;
            return $json->encode(
                $tira->tasklist_next( project => $project, session => $payload->{session} // '' ) // {} );
        },
        tasklist_shift => sub {
            my ($payload) = @_;
            return $json->encode(
                $tira->tasklist_shift( project => $project, session => $payload->{session} // '' ) // {} );
        },
        tasklist_pop => sub {
            my ($payload) = @_;
            return $json->encode(
                $tira->tasklist_pop( project => $project, session => $payload->{session} // '' ) // {} );
        },
        tasklist_unshift => sub {
            my ($payload) = @_;
            die "Task text is required\n" if !defined $payload->{text} || $payload->{text} eq '';
            return $json->encode( $tira->tasklist_unshift(
                project => $project, text => $payload->{text}, session => $payload->{session} // '' ) );
        },
        tasklist_slice => sub {
            my ($payload) = @_;
            die "Task text is required\n" if !defined $payload->{text} || $payload->{text} eq '';
            die "A position is required\n" if !defined $payload->{position};
            return $json->encode( $tira->tasklist_slice(
                project => $project, text => $payload->{text}, position => $payload->{position},
                session => $payload->{session} // '' ) );
        },
        tasklist_remove => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            return $json->encode( $tira->tasklist_remove(
                project => $project, id => $payload->{id}, session => $payload->{session} // '' ) );
        },
        tasklist_import => sub {
            my ($payload) = @_;
            die "A card ref is required\n" if !defined $payload->{ref} || $payload->{ref} eq '';
            return $json->encode( $tira->tasklist_import(
                project => $project, ref => $payload->{ref}, session => $payload->{session} // '' ) );
        },
        tasklist_prune => sub {
            my ($payload) = @_;
            return $json->encode(
                $tira->tasklist_prune( project => $project, session => $payload->{session} // '' ) );
        },
        tasklist_task_attach_add => sub {
            my ($payload) = @_;
            die "Attachment upload requires id, filename, and content\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id} || !defined $payload->{filename}
              || !defined $payload->{content_base64};
            require MIME::Base64;
            my $content = MIME::Base64::decode_base64( $payload->{content_base64} );
            return $json->encode( $tira->tasklist_task_attach_add_content(
                project => $project, id => $payload->{id},
                filename => $payload->{filename}, content => $content,
                session => $payload->{session} // '',
            ) );
        },
        tasklist_task_attach_discard => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            die "A filename is required\n" if !defined $payload->{filename} || $payload->{filename} eq '';
            return $json->encode( $tira->tasklist_task_attach_discard(
                project => $project, id => $payload->{id}, files => [ $payload->{filename} ],
                session => $payload->{session} // '' ) );
        },
        tasklist_task_ref_link => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            die "A ref is required\n" if !defined $payload->{ref} || $payload->{ref} eq '';
            return $json->encode( $tira->tasklist_task_ref_link(
                project => $project, id => $payload->{id}, refs => [ $payload->{ref} ],
                session => $payload->{session} // '' ) );
        },
        tasklist_task_ref_unlink => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            die "A ref is required\n" if !defined $payload->{ref} || $payload->{ref} eq '';
            return $json->encode( $tira->tasklist_task_ref_unlink(
                project => $project, id => $payload->{id}, refs => [ $payload->{ref} ],
                session => $payload->{session} // '' ) );
        },
        tasklist_sessions => sub {
            return $json->encode( $tira->tasklist_sessions( project => $project ) );
        },

        search => sub {
            my ($query) = @_;

            # No type: the board filter searches the whole project, because a
            # question reference can name a card on any board.
            return $json->encode( [] ) if !defined $query->{text} || $query->{text} eq '';
            return $json->encode(
                $tira->search(
                    project => $project, text => $query->{text},
                    ( defined $query->{type} && $query->{type} ne '' ? ( type => $query->{type} ) : () ),
                    refs_only => 1,
                )
            );
        },
        create => sub {
            my ($payload) = @_;
            die "Create payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(type column title)) {
                die "Create payload requires type, column, and title\n"
                  if !defined $payload->{$key} || ref $payload->{$key} || $payload->{$key} eq '';
            }
            my %optional;
            for my $field (qw(description priority assignee reporter)) {
                next if !defined $payload->{$field} || $payload->{$field} eq '';
                die "Field '$field' requires a plain value\n" if ref $payload->{$field};
                $optional{$field} = $payload->{$field};
            }
            $optional{reporter} = $payload->{_signed_in}
              if !defined $optional{reporter} && defined $payload->{_signed_in};
            my $record = $tira->create_record(
                project => $project, type => $payload->{type}, title => $payload->{title},
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
                %optional,
            );
            $record = $tira->record_move(
                project => $project, ref => $record->{ref}, column => $payload->{column},
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
            ) if $payload->{column} ne 'backlog';
            return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
        },
        update => sub {
            my ($payload) = @_;
            die "Update payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref field)) {
                die "Update payload requires ref, field, and value\n"
                  if !defined $payload->{$key} || ref $payload->{$key} || !exists $payload->{value};
            }
            my $field = $payload->{field};
            my $value = $payload->{value};
            if ( $list_editable{$field} ) {
                die "Field '$field' requires an array value\n" if ref $value ne 'ARRAY';
                die "Field '$field' accepts plain text items only\n" if grep { ref $_ || !defined $_ } @{$value};
                my %change;
                if ( $field =~ /\Ascope_(included|excluded)\z/ ) {
                    my $side = $1;
                    my $scope = $tira->record_show( project => $project, ref => $payload->{ref} )->{scope};
                    $change{scope} = { %{ $scope // {} }, $side => $value };
                }
                else {
                    $change{ $list_editable{$field} } = $value;
                }
                my $record = $tira->record_update(
                    project => $project, ref => $payload->{ref},
                    author => $payload->{author} // $payload->{_signed_in}, %change );
                return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
            }
            die "Field '$field' is not editable\n" if !$editable{$field};
            die "Field '$field' requires a plain value\n" if ref $value;
            die "Update base must be a plain value\n" if exists $payload->{base} && ref $payload->{base};
            my $record = $tira->record_update(
                project => $project, ref => $payload->{ref},
                author => $payload->{author} // $payload->{_signed_in}, $field => $value,
                ( exists $payload->{base} ? ( expect => { $field => $payload->{base} } ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
        },
        link_types => sub {
            return $json->encode(
                [ map { { outward => $_->{outward}, inward => $_->{inward} } }
                  @{ $tira->link_type_list( project => $project ) } ]
            );
        },
        ( map {
            my ( $name, $method ) = @{$_};
            ( $name => sub {
                my ($payload) = @_;
                die ucfirst( $name =~ tr/_/ /r ) . " requires parent and child\n"
                  if ref($payload) ne 'HASH'
                  || !defined $payload->{parent} || ref $payload->{parent}
                  || !defined $payload->{child} || ref $payload->{child};
                my $result = $tira->$method(
                    project => $project, parent => $payload->{parent}, child => $payload->{child},
                );
                return $json->encode( { ok => Cpanel::JSON::XS::true, result => $result } );
            } );
        } ( [ hierarchy_link => 'hierarchy_link' ], [ hierarchy_unlink => 'hierarchy_unlink' ],
            [ subitem_link => 'subitem_link' ], [ subitem_unlink => 'subitem_unlink' ] ) ),
        link_add => sub {
            my ($payload) = @_;
            die "Link add requires from, type, and to\n"
              if ref($payload) ne 'HASH'
              || grep { !defined $payload->{$_} || ref $payload->{$_} } qw(from type to);
            my $link = $tira->link_add(
                project => $project, from => $payload->{from},
                type => $payload->{type}, to => $payload->{to},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, link => $link } );
        },
        link_remove => sub {
            my ($payload) = @_;
            die "Link removal requires from, type, and to\n"
              if ref($payload) ne 'HASH'
              || grep { !defined $payload->{$_} || ref $payload->{$_} } qw(from type to);
            my $result = $tira->link_remove(
                project => $project, from => $payload->{from},
                type => $payload->{type}, to => $payload->{to},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, result => $result } );
        },
        checklist_add => sub {
            my ($payload) = @_;
            die "Checklist payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref item status)) {
                die "Checklist add requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my $entry = $tira->checklist_add(
                project => $project, ref => $payload->{ref}, author => $payload->{author} // $payload->{_signed_in},
                item => $payload->{item}, status => $payload->{status},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, entry => $entry } );
        },
        checklist_update => sub {
            my ($payload) = @_;
            die "Checklist payload must be an object\n" if ref($payload) ne 'HASH';
            die "Checklist update requires ref and id\n"
              if !defined $payload->{ref} || ref $payload->{ref} || !defined $payload->{id} || ref $payload->{id};
            my $entry = $tira->checklist_update(
                project => $project, ref => $payload->{ref}, id => $payload->{id},
                author => $payload->{author} // $payload->{_signed_in},
                ( defined $payload->{item} ? ( item => $payload->{item} ) : () ),
                ( defined $payload->{status} ? ( status => $payload->{status} ) : () ),
                ( defined $payload->{command} ? ( command => $payload->{command} ) : () ),
                ( defined $payload->{proof} ? ( proof => $payload->{proof} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, entry => $entry } );
        },
        required_action_update => sub {
            my ($payload) = @_;
            die "Required action payload must be an object\n" if ref($payload) ne 'HASH';
            die "Required action update requires ref and id\n"
              if !defined $payload->{ref} || ref $payload->{ref} || !defined $payload->{id} || ref $payload->{id};
            my $entry = $tira->required_item_update(
                project => $project, ref => $payload->{ref}, id => $payload->{id},
                author => $payload->{author} // $payload->{_signed_in},
                ( defined $payload->{item} ? ( item => $payload->{item} ) : () ),
                ( defined $payload->{status} ? ( status => $payload->{status} ) : () ),
                ( defined $payload->{command} ? ( command => $payload->{command} ) : () ),
                ( defined $payload->{proof} ? ( proof => $payload->{proof} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, entry => $entry } );
        },
        comment_add => sub {
            my ($payload) = @_;
            die "Comment payload must be an object\n" if ref($payload) ne 'HASH';

            # A comment is personal, unlike an assignment or a move - TKT-458.
            # Everywhere else on the board an explicit author is a deliberate
            # override the session defers to; here it is the one thing a
            # signed-in person cannot hand to someone else by picking wrong,
            # so the session wins even over an author the payload names.
            $payload->{author} = $payload->{_signed_in}
              if defined $payload->{_signed_in};
            for my $key (qw(ref author text)) {
                die "Comment payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            die "Project person '$payload->{author}' is inactive\n"
              if grep { $_->{id} eq $payload->{author} && !$_->{active} }
              @{ $tira->person_list( project => $project ) };
            my $comment = $tira->comment_add(
                project => $project, ref => $payload->{ref},
                author => $payload->{author}, text => $payload->{text},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, comment => $comment } );
        },
        comment_update => sub {
            my ($payload) = @_;
            die "Comment payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref comment text)) {
                die "Comment payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }

            # Same reasoning as comment_add (TKT-458): a comment is personal,
            # so the signed-in session is who edited it - not something a
            # client-sent field could override even if it tried to. TKT-466.
            my $comment = $tira->comment_update(
                project => $project, ref => $payload->{ref},
                author => $payload->{_signed_in} // $payload->{author},
                comment => $payload->{comment}, text => $payload->{text},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, comment => $comment } );
        },
        comment_remove => sub {
            my ($payload) = @_;
            die "Comment removal payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref comment)) {
                die "Comment removal requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my $removed = $tira->comment_remove(
                project => $project, ref => $payload->{ref}, comment => $payload->{comment},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, removed => $removed } );
        },
        people => sub {
            return $json->encode(
                [ map { { id => $_->{id}, name => $_->{name} } }
                  grep { $_->{active} } @{ $tira->person_list( project => $project ) } ]
            );
        },
        attachment_fetch => sub {
            my ($payload) = @_;
            die "Attachment fetch requires ref and sha\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref} || !defined $payload->{sha};
            my $got = $tira->attachment_get(
                project => $project, sha => $payload->{sha},
                ( defined $payload->{extension} ? ( extension => $payload->{extension} ) : () ),
            );
            die "Attachment '$payload->{sha}' not found\n" if $got->{deleted};
            my $record = $tira->record_show( project => $project, ref => $payload->{ref} );
            my ($reference) =
              grep { $_->{sha} eq $payload->{sha} }
              ( @{ $record->{attachments} }, map { @{ $_->{attachments} // [] } } @{ $record->{comments} } );
            my $extension = $payload->{extension} // ( $reference ? $reference->{extension} : 'bin' );
            my $filename = $reference ? $reference->{original_filename} : "$payload->{sha}.$extension";

            # An extension in neither of _attachment_content_type's named
            # lists is decided by reading the file's own first bytes
            # (TKT-645) - but only when it is GIVEN the stored path to read.
            # This route omitted it, so the same file's type disagreed with
            # what record_show/attachment_list already tell the card dialog:
            # the dialog said text/plain by sniffing, this route fell
            # through to application/octet-stream having nothing to sniff.
            # TKT-713.
            my $stored = eval { $tira->_attachment_path( $project, sha => $payload->{sha}, extension => $extension ) };
            my $content_type = Tira::CLI::_attachment_content_type( $extension, $stored );
            return {
                content => $got->{content},
                content_type => $content_type,
                filename => $filename,
                inline => $content_type eq 'application/octet-stream' ? 0 : 1,
            };
        },
        attachment_add => sub {
            my ($payload) = @_;
            die "Attachment upload requires ref, filename, and content\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref} || !defined $payload->{filename}
              || !defined $payload->{content_base64};
            require MIME::Base64;
            my $content = MIME::Base64::decode_base64( $payload->{content_base64} );
            my $attachment = $tira->attachment_add_content(
                project => $project, ref => $payload->{ref},
                filename => $payload->{filename}, content => $content,
                ( defined $payload->{comment} ? ( comment => $payload->{comment} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, attachment => $attachment } );
        },
        attachment_discard => sub {
            my ($payload) = @_;
            die "Discard payload must be an object\n" if ref($payload) ne 'HASH';
            my $reference = $tira->attachment_discard(
                project => $project, ref => $payload->{ref}, sha => $payload->{sha},
                extension => $payload->{extension},
                ( defined $payload->{comment} ? ( comment => $payload->{comment} ) : () ),
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
            );
            return Tira::json_object()->canonical->encode(
                { ok => Cpanel::JSON::XS::true, attachment => $reference } );
        },

        attachment_remove => sub {
            my ($payload) = @_;
            die "Attachment removal requires ref and sha\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref} || !defined $payload->{sha};
            my $result = $tira->attachment_detach(
                project => $project, ref => $payload->{ref}, sha => $payload->{sha},
                ( defined $payload->{extension} ? ( extension => $payload->{extension} ) : () ),
                ( defined $payload->{comment} ? ( comment => $payload->{comment} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, %{$result} } );
        },
    );
}

1;

__END__

=head1 NAME

Tira::CLI::Browser - the coderefs the browser dashboard is built from

=head1 DESCRIPTION

C<providers> returns the flat hash of named coderefs L<Tira::DashboardWeb>
requires to build its Dancer2 app - one entry per route, so a browser mutation
can never drift from the engine's own validated command surface.

It lived in C<Tira::CLI> until 4.74, where it was 701 lines of the 6,048 that
had to be read to change any command at all. It is needed by one invocation,
the one that serves a board, so C<Tira::CLI> now loads it with C<require> at
that point - the shape the CLI already used for L<Tira::DashboardWeb> and
L<Tira::OnboardWeb>, and the reason a CLI call that never serves a board never
compiles Dancer2.

=head2 providers

Takes C<tira> and C<project>. Returns the provider hash.

TKT-516 added C<tasklist>, C<tasklist_add>, C<tasklist_update>,
C<tasklist_next>, C<tasklist_shift>, C<tasklist_pop>, C<tasklist_unshift>,
C<tasklist_slice>, C<tasklist_remove>, C<tasklist_import>, C<tasklist_prune>,
C<tasklist_task_attach_add>, C<tasklist_task_attach_discard>,
C<tasklist_task_ref_link>, and C<tasklist_task_ref_unlink>, giving the browser
dashboard's Task List section full parity with C<tira.tasklist.*>.

TKT-540: C<tasklist_update>, C<tasklist_remove>, C<tasklist_task_attach_add>,
C<tasklist_task_attach_discard>, C<tasklist_task_ref_link>, and
C<tasklist_task_ref_unlink> now forward the payload's C<session> field to the
engine, matching the other eight tasklist providers - previously these six
silently dropped it, so a session switched in the dashboard's own session box
could view an item it could not then mutate once TKT-538 began enforcing
session ownership.

TKT-839 added C<jobs>, a read-only provider returning the board's repeated
jobs as JSON for the dashboard's Repeated Jobs section and its C<GET /jobs>
route. Note that adding any name here makes it B<mandatory> -
C<build_psgi_app> refuses a provider hash missing an entry - so a new provider
breaks every hand-built caller that does not also gain it, which is what five
test files had to be taught when this one arrived.

That last sentence is why the section's mutating verbs are three providers and
not four. C<jobs> arrived with none, on the stated grounds that the section
showed a schedule and did not run or edit it; TKT-843 then added C<job_run>,
C<job_check> and C<job_save> for the play button and the editor, and TKT-858
needed creation as well. Creation went into C<job_save> as a dispatch on
whether the payload names a job - no id means C<job_add>, an id means
C<job_update> - rather than becoming a C<job_create> entry, because the page
already posts to one route and each extra name is a breaking change to every
hand-built caller in the suite.

C<jobs> gained one field of its own on TKT-861: C<running>, for enabled
C<monitor>-kind jobs, so the section can say whether a monitor's process is up
rather than only that the job exists. The verdict is
C<Tira::Job::job_monitor_alive> - the same call the C<monitor-dead> rule makes -
because a liveness check written for the browser would let the page and the
police bridge answer one question two ways, which is the fault TKT-860 had to
unpick. The process table is read once per request and only when there is an
enabled monitor to judge; a cron job and a disabled monitor get no field at all,
matching the rule's own silences.

C<job_save> does not validate. C<job_add> and C<job_update> both reach
C<_job_fields>, which owns the schedule requirement and the refusal of a
message-mode monitor, so both paths inherit those rules by asking the engine.
A monitor created through C<job_save> is started with
C<Tira::CLI::Job::run_now>, the same executor C<job_run> uses - Michael's
answer to Q-109 on TKT-858, chosen over creating it stopped, so a monitor made
on the page is not immediately reported dead by C<monitor-dead>. A second
spawn written here would not carry C<run_now>'s already-running refusal or its
spawn/record atomicity fix.

=head2 What is owed in the card's own column

C<providers> exposes C<unmet_in_column>, and the C<detail> provider sets
C<unmet_in_column> on the record it returns. Both call
C<Tira::CLI::_unmet_in_column> - this column, minus exemptions, minus anything
already done - which is the selection C<tira.required-action.list --blocking>
answers with.

That is the whole design of TKT-665 and it is worth stating rather than
inferring. The dialog groups required actions by column and marked none of them,
so a card with a history showed a column of headings and left the reader to work
out which was owed. Marking the current one needs a number, and a number counted
in JavaScript would be a second opinion about what C<done> means - which is the
drift TKT-657 fixed when four readers of one status disagreed about case. So
Perl decides and the browser renders: the dialog compares a column name and
prints a count it was given.

One answer, delivered two ways, deliberately - and only one of them reaches a
browser. The record field is how the dialog gets it, without a fetch on every
open. C<unmet_in_column> itself is NOT served on any HTTP route:
L<Tira::DashboardWeb> declares the fifty-eight providers it serves and this is
not among them, so it is reachable from Perl and nowhere else.

It earns its place regardless. It is the addressable thing C<t/432> pins against
C<--blocking>, compared item by item rather than by count so that a second
implementation agreeing on today's total would still fail - and it is what a
route would call if the dialog ever needed to ask rather than be told.

An earlier draft of this paragraph said "there are two routes to one answer".
In this codebase a route is an HTTP route, and a reader would have concluded the
browser could fetch this. It cannot.

=head2 Why the helpers are written out in full

Six of C<Tira::CLI>'s private helpers are called from here, as
C<Tira::CLI::_attachment_content_type> and so on rather than imported. Nothing
loads this module except C<Tira::CLI>, so that package is always in memory by
the time any of these run.

Qualifying them is deliberate beyond necessity: a reader of this file can see
that the helper lives in the index rather than here, which is the distinction
the split exists to make. An import would have hidden exactly the fact worth
showing.

=head2 How this module is loaded

C<Tira::CLI> pulls this in with C<require> at the point one of its verbs runs,
so a command that never needs it never compiles it. It calls into L<Tira::CLI::Police>, and asks for
that the same way - inside the sub that needs it, not at the top of this
file. A C<use> there is correct and turns a lazy chain eager, which is how
C<tira.next> came to compile four modules for the sake of one helper for the
first hour after the split.

=head1 SEE ALSO

L<Tira::CLI>, L<Tira::DashboardWeb>

=cut
