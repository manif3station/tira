package Tira::CLI::Police;

# Police, the bridge, and the dev-report verb - moved out of Tira::CLI so that
# reading the CLI to change anything else no longer means reading it. The first
# slice moved 368 lines of world-scanning and violation-following; later slices
# brought the two police command bodies and the store and card-in-progress
# readers, and the module is 575 lines of subs today.
# The world scan is the bulk of it: what is running on this machine, which
# containers, which git branches and worktrees, what is unpushed, when the tree
# last changed. None of that is needed by any other command, and all of it was
# in the file every command had to be read through.
# WHAT STAYED IN Tira::CLI AND IS CALLED BY ITS FULL NAME HERE: the backup
# readers (_backup_home, _backup_store, _last_backup, _later_backup,
# _last_backup_commit), which the world scan reads but does not own; the process
# and container primitives (_processes_from, _processes_from_windows,
# _containers_from, _process_command, _reading), which are general; the git
# helpers _is_repository and _tracking_branch; _card_in_progress,
# _dashboard_hup_if_stale, _restart_if_updated, _tira_home and _utf8_bytes.
# Qualifying them is deliberate beyond necessity. A reader of this file can see
# at the call site that the helper lives in the index rather than here, which is
# the distinction the split exists to make; an import would have hidden exactly
# the fact worth showing.

use strict;
use warnings;
use Encode ();
use Fcntl qw(:flock);

use Cwd ();
use File::Spec ();
use Tira;

# Stays here rather than moving with run_due_job into Tira::CLI::Police::Jobs
# (TKT-1043): t/512 localises this exact package variable by its
# fully-qualified name (local $Tira::CLI::Police::RUN_TIMEOUT = -1) to force
# an already-passed deadline, and a variable of the same name declared fresh
# in the new package would be a different variable the test's local() never
# touches. Tira::CLI::Police::Jobs reads this one by its full name instead of
# declaring its own, the same reason its forwarding subs are called by full
# name rather than given their own copy of the logic.
our $RUN_TIMEOUT = 300;

sub police_follow {
    require Tira::CLI::Serve;
    my ( $tira, $args, $store, $option ) = @_;
    my $interval = defined $option->{interval} ? $option->{interval} : 30;
    my $rounds = $option->{rounds};
    my $wait = $option->{sleeper} || sub { sleep $_[0] if $_[0] };

    # d2 tira.police is a singleton, his own words after two live daemons on
    # one board raced the enforcement ledger (TKT-486): "Whoever the last run
    # it is the winner and the loser process will be killed." Claimed once,
    # here, before the watch starts - not for --once, a single pass that is
    # not "a process" in the sense that answer means, and killing a real
    # watcher because something asked it a quick status question would be
    # more surprising than helpful. TKT-492.
    # WHO this pass is, when it was started by something that cannot pass
    # arguments into it. --with-police spawns a separate police process rather
    # than forking one, so the fact that it belongs to a dashboard travels in
    # the environment. An injected singleton wins, so tests still say it
    # directly; an unrecognised value is normalised by the claim itself, so a
    # stray environment cannot buy the protection only the dashboard earns.
    # TKT-897.
    my %singleton = %{ $option->{singleton} // {} };
    $singleton{holder} = $ENV{TIRA_POLICE_HOLDER}
      if !exists $singleton{holder} && defined $ENV{TIRA_POLICE_HOLDER};

    my $claim = police_claim_singleton( $store, %singleton );

    # THE LOSER SAYS WHY AND LEAVES, which is his answer to Q-117 on TKT-897 -
    # "a later tira.police says so and exits 0" - and the reason it exits 0 is
    # that standing aside is the correct outcome rather than a failure. A
    # non-zero status here would make every wrapper treat a working board as a
    # broken one.
    # It says WHICH process holds it, because "something else is running" is the
    # kind of message that sends somebody hunting. EPC-014, TKT-897.
    if ( $claim->{yield} ) {
        print {*STDERR} "police: the browser dashboard is already running police "
          . "(pid $claim->{holding_pid}), and it keeps the watch - so this one is "
          . "standing down rather than taking it over. Its findings appear in the "
          . "terminal running the dashboard.\n";
        return 0;
    }

    print {*STDERR} "police: killed a still-running daemon (pid $claim->{killed}) - only the newest watches now\n"
      if defined $claim->{killed};

    # A supervisor that dies quietly is worse than none, because its silence
    # reads as everything being fine.
    # How it leaves is injectable, so that what it says on the way out can be
    # proved by calling the handler rather than by killing the process - a
    # handler nothing has ever run is a handler nobody knows works.
    my $leave = $option->{leave} || sub { exit 0 };

    # How it replaces itself, injectable for the same reason leaving is: a
    # restart proved by calling the handler is a restart somebody has watched,
    # and one proved by execing the test suite is not.
    my $restarter = $option->{restarter} || \&Tira::CLI::Serve::_restart_into;
    for my $signal (qw(INT TERM HUP)) {
        $SIG{$signal} = sub {
            police_goodbye( $tira, $signal );
            police_release_singleton( $store, %singleton );
            $leave->();
        };
    }
    my $done = 0;

    # Which board this round is about, so the bridge can be told. Set inside the
    # eval that discovers it and cleared at the top of every round, because a
    # round that could not read the board must not write a line about the last
    # one.
    my $watched_board;
    while ( !defined $rounds || $done < $rounds ) {
        $done++;
        undef $watched_board;
        # Gathered every round, not once at the start: a container that comes up
        # an hour into a watch is exactly the kind of thing this is for.
        my $result = eval {
            my $watching = $tira->discover_project( %{$args} );
            $watched_board = $watching;
            $tira->police_pass( %{$args}, store => $store,
                world => police_world( tira => $tira, project => $watching ) );
        };
        if ( !$result ) {
            # Transient trouble is not a reason to stop watching.
            print {*STDERR} 'police could not read the board: ' . ( $@ || 'unknown' ) . "\n";
        }
        else {
            $tira->bridge_write( store => $store, project => $watched_board,
                violations => $result->{violations}, settled => $result->{settled},
            upgraded => $result->{upgraded} );

            # The watch loop matters most of the three: it is the one that runs
            # continuously, so a monitor's output left unrecorded here would be
            # re-announced every round forever.
            # Through _utf8_bytes like every other output path in this file, and
            # for the same reason: STDERR is :raw on purpose (Tira::CLI::run),
            # and this is the print that runs on every poll of the standing
            # watch loop - a violation carrying non-ASCII text (a card title or
            # comment in Cantonese) warned "Wide character in print" on the
            # owner's own screen once per interval, forever, until the process
            # was killed. TKT-939.
            advance_monitor_output( $tira, $args, $result );

            # And the due command-mode jobs actually run. TKT-944: without
            # this the watch loop announces "runs: ..." on every window for
            # ever and nothing happens - which is what it did.
            run_due_commands( $tira, $args, $result );
            print {*STDERR} Tira::CLI::_utf8_bytes( join '', map { "$_\n" } @{ $result->{terminal} } );
        }
        # Into the code that is installed, between rounds.
        # The machinery has existed since the dashboard needed it and nothing
        # here ever called it, so a police left running through a release kept
        # the rulebook it started with: rules that shipped since were not
        # evaluated, wording that had been corrected was still printed, and it
        # said nothing about either - a watcher reading old rules looks exactly
        # like a watcher reading new ones. Reported by the owner on 2026-08-15,
        # and measured on this project's own board an hour later, where a fix
        # that had shipped, passed its gate and reached origin went on being
        # contradicted by the police still running the previous version.
        # Between rounds, never during a pass: police writes the bridge and the
        # enforcement ledger, and a pass cut in half would leave a violation
        # counted and unsaid, or said and uncounted.
        # _restart_if_updated asks whether the code differs rather than whether
        # a label moved, which is what stops this looping - exec loads the same
        # module again and disagrees with .env again, and four dashboards did
        # exactly that every sixty seconds for twenty hours.
        # Once. _restart_into execs and never comes back, so in a running
        # police this can only happen once by construction - but if it ever
        # returns, whether because exec failed or because a caller handed in
        # something that does not exec, carrying on would try again every
        # interval for ever. That is the shape of the loop this whole mechanism
        # was built to avoid, so a restart that returns ends the watch instead:
        # a police that has stopped is visible, and one restarting on a timer
        # is not.
        last
          if defined $watched_board
          && Tira::CLI::Serve::_restart_if_updated( $restarter, 'police', undef, $watched_board );

        # And the board it watches, which cannot do this for itself: under a
        # pre-forked server the process that notices a new version is a
        # worker, and a worker cannot replace the board. Police is outside
        # the pool and owns no socket, so it sends the master a HUP and the
        # workers come back on the installed code, finishing what they hold
        # first. Signalled once per release, never per pass. TKT-565.
        my %hup = %{ $option->{dashboard} // {} };
        if ( !exists $hup{port} && defined $watched_board ) {
            $hup{port} = eval { $tira->project_show( project => $watched_board )->{dashboard}{port} };
        }
        my $board = Tira::CLI::Serve::_dashboard_hup_if_stale( $store, %hup );
        print {*STDERR} "police: told the dashboard (pid $board->{pid}) to reload into $board->{version}\n"
          if $board->{hupped};

        $wait->($interval);
    }
    police_release_singleton( $store, %singleton );    # TKT-1104: matches the claim's own normalized %singleton, same as bridge_follow.
    return { rounds => $done };
}
# The world scan (police_world and its own machine-reading helpers) lives in
# Tira::CLI::Police::World since TKT-1103 - see that module's own header for
# why. police_world keeps this one-line forward: several existing tests and
# Tira::CLI::Job::Monitor call it by this fully-qualified name.
sub police_world {
    require Tira::CLI::Police::World;
    return Tira::CLI::Police::World::police_world(@_);
}
# The claim: read whoever was there before, kill them if they are still
# alive, then write our own pid over theirs. pid/alive/kill are all
# injectable - the same shape leave/restarter/sleeper already use in
# _police_follow - so this is provable without spawning or signalling a
# real OS process. TKT-492.
# TKT-1138: serializes claim/release on the same path. Closed EXPLICITLY,
# not left to scope exit - a caller that closed STDERR/STDOUT first (t/84,
# t/1104, proving a real exit handler) can make this open() land on fd
# 2/1, and Perl does not release a flock held there on scope exit alone,
# which deadlocked the very next claim or release on the same store.
sub _with_singleton_lock {
    my ( $path, $code ) = @_;
    open my $lock, '>>', "$path.lock" or die "Cannot open '$path.lock': $!\n";
    flock( $lock, LOCK_EX ) or die "Cannot lock '$path.lock': $!\n";
    my $result = eval { $code->() };
    my $error = $@;
    close $lock;
    die $error if $error;
    return $result;
}

sub police_claim_singleton {
    my ( $store, %opts ) = @_;
    File::Path::make_path($store) if !-d $store;
    my $path = police_singleton_path( $store, $opts{kind} );
    return _with_singleton_lock( $path, sub { _police_claim_singleton_locked( $path, %opts ) } );
}

sub _police_claim_singleton_locked {
    my ( $path, %opts ) = @_;
    my $my_pid = $opts{pid} // $$;
    my $alive = $opts{alive} || sub { return kill 0, $_[0] };
    my $kill_previous = $opts{kill} || sub { kill 'TERM', $_[0] };

    # WHO is claiming, not just which pid. His answer to Q-117 on TKT-897:
    # "The dashboard is a special case - while it holds police, a later
    # tira.police says so and exits 0. TKT-486 still applies everywhere else."
    # A bare pid cannot express that - a later claimant reading the file has to
    # be able to tell a dashboard from an ordinary daemon before it decides
    # whether to kill it or stand down. TKT-1100 gave policy.bridge the
    # identical claim, keyed by its own kind of file (police_singleton_path's
    # own $kind), so "ordinary" here means whichever kind is claiming - a
    # policy.bridge claim's ordinary holder is 'policy-bridge', not 'police'.
    # NORMALISED TO THE TWO STATES THAT EXIST, rather than trusting whatever
    # arrives. A review pointed out that the first version preserved the bare-pid
    # write only for the exact string 'police': holder => '' wrote "1234 " with a
    # trailing space, and holder => 'Police' wrote a second field - so a caller
    # being slightly wrong changed the on-disk format that three other tests read.
    # There are two holders, not a free-text field, and saying so here means an
    # unrecognised one is ordinary rather than a new kind of record.
    my $ordinary_holder = $opts{kind} // 'police';
    my $my_holder = ( $opts{holder} // '' ) eq 'dashboard' ? 'dashboard' : $ordinary_holder;

    my $killed;
    if ( open my $fh, '<', $path ) {
        my $previous = do { local $/; <$fh> };
        close $fh;

        # Two fields now, and the second is optional so a file written by an
        # older version - a bare pid - still reads correctly as an ordinary
        # police daemon rather than as a malformed claim.
        # Read the same way it is written: a pid, and at most one holder that
        # means anything. Anything else in the file - a third token, a
        # hand-edit, a partial write - reads as an ordinary claim rather than as
        # a dashboard, because the failure that matters is a stranger being
        # treated as the one holder nobody may kill.
        my @field = split ' ', ( $previous // '' );
        my $previous_pid = @field ? $field[0] : '';

        # EXACTLY what this code writes, or it is an ordinary claim. Two fields
        # and the second is 'dashboard' - a third token, a different word, a
        # hand-edit or a partial write all read as ordinary. The direction is
        # chosen rather than incidental: the dashboard is the one holder nobody
        # may kill, so anything the parser is unsure about must fall on the side
        # of the ordinary rule, where the worst case is a process being replaced
        # as it always was. Falling the other way would let a malformed file
        # protect a stranger.
        my $previous_holder =
          ( @field == 2 && $field[1] eq 'dashboard' ) ? 'dashboard' : 'police';

        if ( length $previous_pid && $previous_pid ne $my_pid && $alive->($previous_pid) ) {

            # THE ONE EXCEPTION, and it is scoped exactly as he scoped it: an
            # ordinary police finding the DASHBOARD in possession stands down.
            # It does not kill, and it does not write - a loser that stamped its
            # own pid on the way out would leave the record naming a process
            # about to exit while the dashboard ran on unrecorded, which is the
            # board saying something untrue about a live process.
            # A dashboard meeting a dashboard falls through to the ordinary rule
            # deliberately: the exception is about the dashboard outranking
            # police, not about dashboards being immortal.
            if ( $previous_holder eq 'dashboard' && $my_holder ne 'dashboard' ) {
                return {
                    yield       => 1,
                    holder      => $previous_holder,
                    holding_pid => $previous_pid,
                };
            }

            $kill_previous->($previous_pid);
            $killed = $previous_pid;
        }
    }
    # THE ORDINARY CLAIM IS WRITTEN EXACTLY AS IT ALWAYS WAS - a bare pid - and
    # only the dashboard adds a marker. Nothing about TKT-486's case has
    # changed, so nothing about its record should: a format that grew a second
    # field for every claimant would rewrite a file three other tests read, to
    # describe a situation that is still the default. t/373 asserting the file
    # holds the pid and nothing else is a fair thing to assert, and it caught
    # this when the first version wrote the holder unconditionally.
    open my $fh, '>', $path or die "Cannot claim the police singleton at '$path': $!\n";
    print {$fh} ( $my_holder eq 'dashboard' ? "$my_pid dashboard" : $my_pid );
    close $fh;
    return { claimed => $my_pid, killed => $killed, holder => $my_holder };
}
# Split out from the signal handler so that what police says on its way out can
# be called and checked, rather than only reached by killing the process.
sub police_goodbye {
    my ( $tira, $signal ) = @_;
    print {*STDERR} $tira->police_farewell( reason => "signal $signal" ) . "\n";
    return 1;
}
# The pid file is this process's own claim, so a clean exit removes it
# rather than leaving a stale entry the next daemon's alive-check has to
# reason past. A daemon that dies uncleanly (kill -9, a crash) leaves the
# file behind - the next claim's alive-check still handles that safely,
# since a dead pid answers false and nothing is killed.
# OWNERSHIP-AWARE, since TKT-1100's Codex review caught the race this always
# had: a successor can claim (kill us, write ITS OWN pid) before our signal
# handler gets to run this. Releasing unconditionally would then delete the
# SUCCESSOR's claim, not ours, leaving the board looking unwatched while a
# live daemon runs on with no pid file naming it. Reading the file back and
# comparing the pid it names to our own before removing means a claim we no
# longer hold is left exactly as the successor wrote it.
sub police_release_singleton {
    my ( $store, %opts ) = @_;
    my $path = police_singleton_path( $store, $opts{kind} );
    # A missing store is nothing to release, same as before TKT-1138: the
    # lock file lives beside the pid file, so opening it would die where
    # a plain unlink used to just fail quietly (Codex review).
    return if !-d $store;
    return _with_singleton_lock( $path, sub { _police_release_singleton_locked( $path, %opts ) } );
}

sub _police_release_singleton_locked {
    my ( $path, %opts ) = @_;
    my $my_pid = $opts{pid} // $$;
    my $remove = $opts{unlink} || sub { unlink $_[0] };

    if ( open my $fh, '<', $path ) {
        my $content = do { local $/; <$fh> };
        close $fh;
        my ($stored_pid) = split ' ', ( $content // '' );
        return if !defined $stored_pid || $stored_pid ne $my_pid;
    }
    $remove->($path);
    return;
}
# Where the singleton claim lives - beside the enforcement ledger itself,
# since both are per-store, not per-project. $kind names which watcher this
# is: undef/'police' keeps the original filename so every existing claim and
# every test that reads it verbatim (t/373) still finds the same file;
# TKT-1100 gave policy.bridge its own file rather than sharing police's, since
# a bridge and a police daemon started by the same dashboard are not rivals
# for the same slot - each needs its own newest-wins rule.
sub police_singleton_path {
    my ( $store, $kind ) = @_;
    $kind //= 'police';
    my $name = $kind eq 'police' ? '.police.pid' : ".$kind.pid";
    return File::Spec->catfile( $store, $name );
}
# A loop that never ends cannot be called by anything, including a test - so
# the number of rounds and the waiting are both injectable. Left alone it runs
# for ever, which is what an agent tailing a bridge wants.
sub bridge_follow {
    my ( $tira, $store, %args ) = @_;
    my $rounds = $args{rounds};
    my $wait = $args{sleeper} || sub { sleep $_[0] if $_[0] };
    my $every = defined $args{interval} ? $args{interval} : 2;
    my $path = $tira->bridge_log_path( store => $store );

    # d2 tira.policy.bridge is a singleton for the same reason police is
    # (TKT-1100): repeated `d2 tira.dashboard` starts each spawned their own
    # bridge watcher beside the police one, and nothing ever stopped an older
    # one when a newer dashboard came up - police already had this because
    # police_follow claims before its loop starts (TKT-492/897); bridge_follow
    # never did. Same claim mechanism, a different file
    # (police_singleton_path's own 'policy-bridge' kind), so a bridge and a
    # police daemon from the same dashboard are not each other's rivals.
    my %singleton = %{ $args{singleton} // {} };
    $singleton{kind} = 'policy-bridge';
    $singleton{holder} = $ENV{TIRA_POLICY_BRIDGE_HOLDER}
      if !exists $singleton{holder} && defined $ENV{TIRA_POLICY_BRIDGE_HOLDER};

    my $claim = police_claim_singleton( $store, %singleton );
    if ( $claim->{yield} ) {
        print {*STDERR} "policy.bridge: the browser dashboard is already running policy.bridge "
          . "(pid $claim->{holding_pid}), and it keeps the watch - so this one is "
          . "standing down rather than taking it over.\n";
        return 0;
    }
    print {*STDERR} "policy.bridge: killed a still-running daemon (pid $claim->{killed}) - only the newest watches now\n"
      if defined $claim->{killed};

    my $leave = $args{leave} || sub { exit 0 };
    for my $signal (qw(INT TERM HUP)) {
        $SIG{$signal} = sub {

            # Releasing %singleton itself, the same hash the claim above used
            # (kind forced to 'policy-bridge' there already) - not a fresh
            # 'kind => ... , %{ $args{singleton} }' construction, which a
            # caller-supplied singleton{kind} would win over the forced
            # 'policy-bridge' in a plain hash literal (Codex review, TKT-1100)
            # and release a file the claim never wrote.
            police_release_singleton( $store, %singleton );
            $leave->();
        };
    }

    # Counted through the same filter the agent reads through, or a line
    # written for somebody else would advance the mark and swallow the next
    # line that was actually for this one.
    my %narrow = ( store => $store, lines => 1_000_000,
        ( defined $args{agent} ? ( agent => $args{agent} ) : () ) );
    my $seen = -f $path ? scalar @{ $tira->bridge_backlog(%narrow) } : 0;
    my $done = 0;
    while ( !defined $rounds || $done < $rounds ) {
        $done++;
        $wait->($every);
        my $all = $tira->bridge_backlog(%narrow);
        next if @{$all} <= $seen;
        # Encoded here too, and not only in the replay: fixing the first screen
        # and leaving every line after it wrong is the worse half, because a
        # tail is what an agent leaves running.
        print Tira::CLI::_utf8_bytes( join '', map { "$_\n" } @{$all}[ $seen .. $#{$all} ] );
        $seen = scalar @{$all};
    }
    police_release_singleton( $store, %singleton );    # TKT-1104: same gap as police_follow's normal exit above.
    return $seen;
}
# An agent working on something else, reporting a fault in Tira. It knows what
# it found and which project it is; it is told nothing about where the report
# goes, which is the whole reason this exists rather than an instruction to go
# and find the board.
sub report_to_tira {
    my ( $tira, $args, $option ) = @_;

    my $from = $option->{from};
    die "Which project is this coming from? Say so: --from <project>\n"
      . "A report nobody can go back to is a report nobody can answer.\n"
      if !defined $from || $from !~ /\S/;

    my $title = $option->{title};
    die "What did you find? Give it a title: --title <what happened>\n"
      if !defined $title || $title !~ /\S/;

    my $card = $tira->create_record(
        project  => Tira::CLI::_tira_home(),
        type     => 'ticket',
        title    => $title,

        # Raised as the owner. An agent in another project is not a member of
        # this board, and inventing a member per caller would fill the roster
        # with names nobody here works with. The origin is a label instead, so
        # the report can be found again and answered on the card.
        reporter    => 'michael',
        labels      => [$from],
        description => $option->{text} // '',
        source      => "Reported from $from through tira.dev.found.bug_or_improvement",
    );

    # What comes back names the card and nothing else. A path here would teach
    # the caller the one thing this command exists to keep from it.
    return {
        ref     => $card->{ref},
        from    => $from,
        message => "Reported as $card->{ref}. Somebody will pick it up; ask about it there.",
    };
}
# Run a due command-mode job and hand back what it produced. TKT-841.
# THIS IS WHERE EXECUTION LIVES, and the placement is decided by a test rather
# than by taste. t/106 forbids qx, system(, exec( and piped open anywhere in
# the engine, and its pattern catches list-form system( too - so "no shell"
# buys no exception there. Suite::engine_source() already excludes
# lib/Tira/CLI because Serve.pm legitimately shells out to serve a board, so
# the CLI layer is the sanctioned home and no second exception was invented.
# The engine announces a due job; this runs it.
# LIST FORM, NEVER A SHELL STRING. The command is split on whitespace and
# handed to open3 as a list, so the program is named separately from its
# arguments and a semicolon in a command is an argument rather than an
# instruction. The cost is honest and worth stating: there is no quoting, so
# `echo "two words"` is four arguments, not two. Jobs on this board run
# commands like `d2 tira.police.bridge`; a job needing quoting should be a
# script, which is also the answer that keeps the no-shell guarantee.
# STDERR IS CAPTURED WITH STDOUT because a failing command usually says why on
# stderr, and the whole point of this card is that a job which ran and failed
# must be distinguishable from one that never ran. Dropping stderr would leave
# the bridge saying "it failed" with no reason, which is a smaller version of
# the same silence.
# What the pass read from each monitor's spool, written back AFTER the bridge
# has it. TKT-851.
# THE ENGINE DELIBERATELY DOES NOT DO THIS. My first version advanced the offset
# inside the rule, under the same lock as the announcement, on the grounds that
# announcing and advancing must not drift apart. t/86 overturned it: it
# fingerprints the board across a pass and asserts that one which "found twenty
# different things wrong changed not one byte". Police observes and does not
# mutate, and that guarantee is older and better established than my argument
# against it.
# So the split is the one this epic already uses for job-due - announce in the
# engine, act in the CLI - and the drift I was worried about is answered by
# doing it here, in the same command, immediately after the write rather than
# in some later pass.
# ORDER MATTERS. The bridge write comes first: if this ran before it and the
# write then failed, the offset would have moved past output nobody ever saw,
# which is the exact loss this rule exists to prevent.
# TKT-944. THE STEP THAT WAS NEVER WIRED. TKT-841 built run_due_job below and
# its own card said what it was for: "an execution step reached from the
# job-due evaluation: when a due job is command-mode, run its command". The
# executor shipped and the step did not. Its only caller anywhere in lib/ or
# cli/ was Tira::CLI::Job::run_now - the manual Run now button - so a
# command-mode job was announced on the bridge as "runs: ..." every time its
# window came round and was never once executed by a pass.
# Measured before this existed, on a scratch board: a job due every minute
# whose command was `/bin/touch <witness>`, one pass past the window. The
# bridge printed the announcement; the witness file was never created. On the
# real board that is JOB-004 - `d2 tira.police.outstanding`, every thirty
# minutes - announcing itself and doing nothing, for as long as it has
# existed.
# HERE RATHER THAN IN THE ENGINE, and that is not a preference. t/489 asserts
# the job-due rule body runs nothing and t/492 asserts the whole engine does;
# Suite::engine_source() excludes lib/Tira/CLI precisely so execution has a
# sanctioned home. The engine names the due jobs in the pass result and this
# runs them - the same division advance_monitor_output already uses for a
# monitor's leavings, and for the same reason.
# WHAT IT PRINTED IS KEPT. job_feed is the pipe a monitor's output already
# travels, so a cron run's output lands on the job's own `recent` tail and
# stamps last_output_at - the run becomes something a reader can see rather
# than something they are asked to believe. Carrying it onward to the BRIDGE
# is a separate question: the monitor-output rule is gated to
# schedule_kind 'monitor', and widening a rule that carries that name is a
# decision about what the rule means, which is asked on the card rather than
# taken here.
# ONE JOB'S FAILURE MUST NOT TAKE THE PASS DOWN, the same stance every other
# job read in this file takes: a command that dies, or output that cannot be
# recorded, is reported through the return value and the loop continues to the
# next job.
# WHAT A RUN LEAVES BEHIND, in one place because two callers need it.
# TKT-963, his report: tira.job.run answered ran=1 status=0 and left the job
# record untouched, so a job that had just run went on reading "Never fired".
# The scheduled path recorded output and the manual one recorded nothing, and
# the fix is not to teach run_now the same steps - it is to have one recorder
# both of them go through. Two functions doing the same job separately is the
# fault this module has already paid for twice: TKT-932 and TKT-953 on
# decoding a child's output, TKT-949 and TKT-962 on absent versus empty.
# THE STAMP FOLLOWS THIS FILE'S OWN MEANING OF "ran" rather than inventing a
# second one. run_due_job answers ran => 1 for a program that is not there -
# "a program that is not there is a RESULT, not a crash" - and ran => 0 for a
# job that runs no command at all. So a missing program records a run, with
# what went wrong in the output lines where TKT-950 put it, and a message-mode
# job records none.
# The output is fed only when there IS output, unchanged from before. The
# stamp is not: a command that exits 0 silently still ran, and recording
# nothing for it was what made "ran" and "was due" the same reading.
# The due-job execution block (record_run, run_due_commands,
# advance_monitor_output, run_due_job) is lifted into Tira::CLI::Police::Jobs
# - TKT-1043, the same week TKT-1041/TKT-1042 lifted the other two
# oversized files' own separable concerns. Reached through a forward of
# the same name, required at the point of use: several existing
# tests monkey-patch these subs by their fully-qualified
# Tira::CLI::Police:: name (t/564, t/570), and a forward preserves that -
# the override replaces the stub every caller actually calls.
sub record_run {
    require Tira::CLI::Police::Jobs;
    return Tira::CLI::Police::Jobs::record_run(@_);
}
sub run_due_commands {
    require Tira::CLI::Police::Jobs;
    return Tira::CLI::Police::Jobs::run_due_commands(@_);
}
sub advance_monitor_output {
    require Tira::CLI::Police::Jobs;
    return Tira::CLI::Police::Jobs::advance_monitor_output(@_);
}
sub run_due_job {
    require Tira::CLI::Police::Jobs;
    return Tira::CLI::Police::Jobs::run_due_job(@_);
}

# Tira::CLI::Job::Monitor's own liveness check calls this by its
# fully-qualified name, and so do several existing tests - kept as a forward
# to Tira::CLI::Police::World since TKT-1103.
sub _running_processes {
    require Tira::CLI::Police::World;
    return Tira::CLI::Police::World::_running_processes(@_);
}
# Called directly by its fully-qualified name from existing tests (t/107).
sub _running_containers {
    require Tira::CLI::Police::World;
    return Tira::CLI::Police::World::_running_containers(@_);
}
# Called directly by its fully-qualified name from existing tests (t/107,
# t/998).
sub _unpushed_commits {
    require Tira::CLI::Police::World;
    return Tira::CLI::Police::World::_unpushed_commits(@_);
}
# Called directly by its fully-qualified name from an existing test (t/998).
sub _tree_changing_since {
    require Tira::CLI::Police::World;
    return Tira::CLI::Police::World::_tree_changing_since(@_);
}

# The two command bodies, lifted out of Tira::CLI::_invoke rather than out of
# its helpers - the first piece of what TKT-607 calls the hard half. _invoke was
# 1,294 lines, and only about fifty of them are the dispatcher; the rest are
# per-command blocks like these two, each of which belongs with the concern it
# is about rather than in the file every other command has to be read through.
# They take \%args rather than reading a lexical, which is the only thing that
# had to change: inside _invoke they closed over %args, $option and $command,
# and here those arrive as arguments. Nothing else in either block moved.

# When the last pass ran, and whether that is recent enough to trust.
# tira.police.outstanding answers what is outstanding AS OF THE LAST PASS, and
# on a clean board that answer is an empty list. On a board whose bridge stopped
# eleven hours ago it is also an empty list - the same bytes, with no field to
# compare. Measured on zenandi, 2026-08-29: a pass at 03:38:41 read at 14:41:50,
# unchanged, while the board reported itself clean all day and a card-duration
# policy sat an hour past its age in that silence.
# WHY A SECOND COMMAND RATHER THAN A RICHER PAYLOAD. Q-096, answered by the owner
# and marked ok: "Keep the bare list and add a separate command for freshness
# [...] Nothing breaks anywhere; the cost is a second command to remember and a
# question answered somewhere other than where it is asked." Two other projects
# pipe and index that payload in the loop they use to decide whether work is
# finished, and docs/commands.md promises it stays a list. TKT-354 chose
# one-shape-always for tira.next in 3.48 and that precedent does not transfer:
# that command had no documented consumers outside this board.
# The cost he named is paid in police_outstanding's own human output, which names
# this command when the pass it is reporting on is stale - so the answer is one
# command away from the question rather than a documentation lookup. TKT-684.
sub police_freshness {
    my ( $tira, $args, $option ) = @_;
    my %args = %{$args};
    my $store = $option->{store}
      // _police_store( $tira->discover_project(%args) );

    my $answer = $tira->police_freshness( store => $store );
    return $answer if ( $option->{output} // '' ) eq 'json';

    return ['This board has never been policed, so nothing has been checked']
      if !defined $answer->{taken_at};

    # A stamp we cannot read is reported as unreadable rather than printed as
    # though it were usable. "last pass <garbage>" with no further comment reads
    # as data; saying it cannot be read says what the caller actually knows.
    # TKT-1094: age_seconds can also be undef because the CLOCK reading (not
    # the stored stamp) failed to parse - unreachable in production but
    # reachable with an injected test clock. Named only when actually the
    # cause; the ordinary case's wording is unchanged.
    return [ 'last pass ' . $answer->{taken_at} . ' - UNREADABLE'
          . ( ( $answer->{unreadable} // '' ) eq 'clock'
            ? ' (the clock reading used to compute its age could not be parsed, not the stored pass time)'
            : '' )
          . ', so nothing can be judged from it and an empty answer'
          . ' from tira.police.outstanding means nothing' ]
      if defined $answer->{taken_at} && !defined $answer->{age_seconds};

    return [
        'last pass ' . $answer->{taken_at}
          . ', ' . Tira::_human_seconds( $answer->{age_seconds} ) . ' ago'
          . ( $answer->{stale}
            ? ' - stale, so an empty answer from tira.police.outstanding means nothing' : '' )
    ];
}

sub police_outstanding {
    my ( $tira, $args, $option ) = @_;
    my %args = %{$args};
    my $store = $option->{store}
      // _police_store( $tira->discover_project(%args) );

    # A read, by default - fast, and answering from whatever the watcher
    # last wrote. --fresh runs the same pass the watcher would, inline,
    # before reading: fixing a violation and asking right away used to
    # mean it could still read as open for up to the watcher's own
    # interval (30s by default), because nothing had told the ledger the
    # fix happened. The loop that clears outstanding violations asks this
    # after every fix, so a stale answer here reads as "still broken" when
    # the truth is "not yet asked again". TKT-423.
    if ( $option->{fresh} ) {
        my $watching = $tira->discover_project(%args);
        require Tira::CLI::Police;
        my $result = $tira->police_pass( %args, store => $store,
            world => police_world( tira => $tira, project => $watching ) );
        if ( $result->{watching} ) {
            $tira->bridge_write( store => $store, project => $watching,
                violations => $result->{violations}, settled => $result->{settled},
                upgraded => $result->{upgraded} );
            advance_monitor_output( $tira, \%args, $result );
        }
    }
    my $open = $tira->police_outstanding( %args, store => $store );

    # What was actually found, said before the answer is dressed up. The
    # exit status used to be taken from the rendered rows, which was true
    # only while a command's output WAS its findings - 2.62 gave this
    # command a summary and a clean board started exiting 1, saying "No
    # violations outstanding" and signalling that there were some. A
    # command that knows its count says so; rendering cannot move the
    # signal afterwards. TKT-385.
    $option->{findings_count} = scalar @{$open};

    # -o json is the payload and stays a bare list. The instruction that drives
    # the clear-violations loop pipes it and indexes the result, and two other
    # projects run that loop.
    # DECIDED, not deferred. This comment used to say the list stays because
    # "TKT-354 is already open about tira.next answering with a dict when work
    # waits and a list when it does not - the same fault from the other side".
    # TKT-354 closed in 3.48 and chose the OPPOSITE: one shape always, a hash,
    # over documenting the inconsistency. So this cited a card that had decided
    # against it, for a year of releases, and nobody noticed because a deferral
    # reads like a reason.
    # Q-096 settled it here, and reached the same conclusion for a current
    # reason: "Keep the bare list and add a separate command for freshness [...]
    # Nothing breaks anywhere; the cost is a second command to remember and a
    # question answered somewhere other than where it is asked." tira.next had
    # no documented consumers outside this board; this payload has two, and
    # docs/commands.md promises them a list. That command is police_freshness
    # above, and the cost he named is paid by the warning below, which names it.
    # TKT-684.
    # Everything below is the human summary the CLI contract asks for.
    return $open if ( $option->{output} // '' ) eq 'json';

    my $at = $tira->police_outstanding_taken_at( store => $store );

    # The age is JUDGED, not merely printed. Until 4.78 the timestamp was here
    # and nothing said whether it was any good, so a pass from ten seconds ago
    # and one from eleven hours ago rendered identically - and the sentence a
    # reader is meant to trust came first. Measured on zenandi: "No violations
    # outstanding, as of the pass at 2026-08-29T03:38:41+0100" on every
    # thirty-minute run for eleven hours, because nothing had run a pass since
    # 03:38. The staleness goes BEFORE the reassurance, because a reader who has
    # already read "No violations outstanding" has stopped reading. TKT-684.
    my $fresh = $tira->police_freshness( store => $store );
    my $warning =
      ( $fresh->{stale} && defined $at )
      ? 'STALE: the last pass was ' . $at
      . ( defined $fresh->{age_seconds}
        ? ', ' . Tira::_human_seconds( $fresh->{age_seconds} ) . ' ago' : '' )
      . ' - the detector may have stopped, so what follows may not describe the board now.'
      . ' Ask tira.police.freshness.'
      : undef;

    return [
        ( defined $warning ? ($warning) : () ),
        defined $at
        ? 'No violations outstanding, as of the pass at ' . $at
        : 'This board has never been policed, so nothing has been checked'
    ] if !@{$open};

    # His question, which the old output could not answer: "why the action
    # all log only? this outstanding command is act-on-it when the agent
    # look at this. they won't act on it but just log only." Both kinds come
    # back tone 'note', so tone cannot carry the difference and the action
    # has to be said.
    my @chased   = grep { ( $_->{action} // '' ) ne 'log-only' } @{$open};
    my @recorded = grep { ( $_->{action} // '' ) eq 'log-only' } @{$open};
    my $line = sub {
        my ($v) = @_;
        return sprintf '%s %s %s seen %d',
          $v->{id} // '', $v->{rule} // '', $v->{ref} // '(board)', $v->{seen} // 0;
    };

    # Each row its own answer rather than a cell in one. TOON renders an
    # array of plain strings as a single inline "primitive array" row -
    # every finding comma-joined behind one bracketed count, quote marks
    # and all - so a reader had to parse past that to find the first
    # thing. An array of single-key hashes is a different shape to TOON:
    # one row per element, which is the whole fix. TKT-291.
    my $row = sub { return { line => $_[0] } };
    # The non-empty case is the one nobody thinks about, and it is worse rather
    # than better: "5 outstanding, as of the pass at <ts>" reads as a live count,
    # so a reader acts on a list that may describe a board eleven hours gone. The
    # card asks for both outputs, and the warning goes first here too.
    my $header = scalar(@{$open}) . ' outstanding, as of the pass at '
      . ( $at // 'a time this board did not record' );
    $header = "$warning\n$header" if defined $warning;

    # Grouped by rule instead of by chased/recorded, opt-in: --by-rule
    # answers "what does this board have declared against it" rather than
    # "what should I do next" - a different question, not a strictly
    # better one, so the default stays the work list. Still-act-on rules
    # sort before log-only ones, so a reader scanning groups meets the
    # same order the default view already gives findings in. Each ref
    # appears once per rule even if two policies for the same rule both
    # matched it - a display duplicate would be one thing on the board
    # read as two.
    if ( $option->{by_rule} ) {
        my %by_rule;
        my %seen;
        for my $v ( @{$open} ) {
            my $rule = $v->{rule} // '';
            next if $seen{$rule}{ $v->{ref} // '' }++;
            push @{ $by_rule{$rule} }, $v;
        }
        my @groups;
        for my $rule (
            ( sort grep { ( $by_rule{$_}[0]{action} // '' ) ne 'log-only' } keys %by_rule ),
            ( sort grep { ( $by_rule{$_}[0]{action} // '' ) eq 'log-only' } keys %by_rule ),
        ) {
            my @findings = @{ $by_rule{$rule} };
            push @groups, $row->( "$rule (" . scalar(@findings) . '):' );
            push @groups, map { $row->( '  ' . $line->($_) ) } @findings;
        }
        return [ $row->($header), @groups ];
    }

    return [
        $row->($header),
        ( @chased
            ? ( $row->( scalar(@chased) . ' to act on:' ),
                ( map { $row->( '  ' . $line->($_) ) } @chased ) )
            : () ),
        ( @recorded
            ? ( $row->( scalar(@recorded)
                  . ' only recorded, because the board declared them log-only:' ),
                ( map { $row->( '  ' . $line->($_) ) } @recorded ) )
            : () ),
    ];
}

sub police_run {
    my ( $tira, $args, $option, $command ) = @_;
    my %args = %{$args};
    my $store = $option->{store}
      // _police_store( $tira->discover_project(%args) );

    if ( $command eq 'policy.bridge' ) {

        # Line by line, whatever this is attached to. Perl block-buffers
        # standard output when it is not a terminal, so redirected to a file
        # - the natural way to leave something running - the bridge wrote
        # nothing for sixty-eight measured minutes while violations
        # escalated to critical. The agent's only channel for violations was
        # silent, and a channel silent because it is buffered looks exactly
        # like a board that is clean.
        # Localised rather than set through the handle. STDOUT->autoflush
        # was tried first and took the stream away from every later caller
        # in the process - four test files went quiet at once - which is the
        # same fault _running_quietly made by reopening it. Nothing here
        # belongs to this command after it returns.
        local $| = 1;

        # Who is tailing it. One agent per ticket means an agent's concern
        # is its own cards, so the bridge narrows to whoever says who they
        # are - by --author, or by TIRA_AUTHOR in the environment, said
        # once rather than on every command. Nobody named hears everything,
        # which is how the owner watches the whole board.
        my $agent = $option->{author};
        my $backlog = $tira->bridge_backlog( store => $store, lines => 200, agent => $agent );

        # Through _utf8_bytes like every other output path. Standard output
        # is deliberately :raw - Perl's text layer on Windows rewrites
        # newlines and Tira compares output bytes in its own cache - so a
        # print of decoded characters warns above U+00FF and, worse, writes
        # a single latin-1 byte between U+0080 and U+00FF without warning.
        # A card title carrying a multiplication sign put exactly the byte
        # tira.doctor repairs into the channel that reports it.
        print Tira::CLI::_utf8_bytes( join '', map { "$_\n" } @{$backlog} );
        require Tira::CLI::Police;
        bridge_follow( $tira, $store, rounds => $option->{rounds}, agent => $agent,
            interval => $option->{interval}, sleeper => $option->{sleeper},
            singleton => $option->{singleton}, leave => $option->{leave} )
          if !$option->{once};
        return { streamed => scalar @{$backlog} };
    }

    # Before anything is reported: what to hand the agent. Police watching a
    # board nobody has set up finds nothing, and that silence looks exactly
    # like compliance - so the owner gets something to copy across rather
    # than writing the instructions himself every time. Printed on every
    # run, because remembering which run was the first is the sort of thing
    # he should not have to do.
    # That was a promise this comment made and the engine did not keep. A
    # board with every rule declared got undef and printed nothing, so it
    # looked exactly like a police that had died - and the boards it
    # happened to were the ones set up most carefully. Every state answers
    # now, so this line is true as written.
    my $prompt = eval { $tira->police_prompt(%args) };
    print {*STDERR} "\n$prompt\n" if defined $prompt;

    # Discovered once and handed to both. The bridge line carries the way
    # down to its card, and that path used to be looked up from the working
    # directory because this call did not say which board it was about - so
    # a violation on one board was reported with a hierarchy from whichever
    # Tira project the process happened to be standing in.
    my $watching = $tira->discover_project(%args);
    require Tira::CLI::Police;
    my $result = $tira->police_pass( %args, store => $store,
        world => police_world( tira => $tira, project => $watching ) );
    die "$result->{advice}\n" if !$result->{watching};
    $tira->bridge_write( store => $store, project => $watching,
        violations => $result->{violations}, settled => $result->{settled},
        upgraded => $result->{upgraded} );
    advance_monitor_output( $tira, \%args, $result );

    # TKT-944, and DELIBERATELY NOT ON EVERY PASS. The two paths wired are the
    # ones that are actually the scheduler: this one and the watch loop above.
    # police_outstanding --fresh runs a pass too, and is left alone on purpose
    # - it is a question about the board, and a status query that executes
    # commands as a side effect of being asked is a surprise nobody consented
    # to. Its own documentation already calls --fresh opt-in because a pass is
    # a write; running arbitrary commands is a great deal more than a write.
    run_due_commands( $tira, \%args, $result );
    print {*STDERR} Tira::CLI::_utf8_bytes( join '', map { "$_\n" } @{ $result->{terminal} } );
    return $result if $option->{once};
    require Tira::CLI::Police;
    return police_follow( $tira, \%args, $store, $option );
}

# The police store's location, and whether a card is being worked. Both stayed
# in the index through the first police slice and neither is anybody else's.
# TKT-607.

# Whether anything on the board is being worked. work-without-card asks it the
# other way round - a tree that is changing while nothing is at a working gate
# is work nobody can see - so getting this wrong makes that rule accuse the
# agent of exactly what it is in the middle of doing properly.
sub _card_in_progress {
    my ( $tira, $root ) = @_;
    return undef if !$tira || !defined $root;
    # Where work happens, asked of the board rather than read off one role.
    # This counted a card as being worked only if it sat in the single column
    # named by the in-progress role, when a board declared one. On this project's
    # own board - in-progress=implement, five columns work happens in - that left
    # tests-red, verify, document and push reading as nobody working, and
    # work-without-card raised VIO-0013 to CRITICAL five times while a card sat
    # in verify with its suite running.
    # A setting that names one column stops covering the board the moment work
    # happens in another, which is the fault column-unwatched reports for
    # policies. The role was accurate when it was set; the board grew.
    # The same question card-unassigned and priority-skipped ask: not protected,
    # and not an ending. A board that has marked nothing terminal ends in `done`,
    # which is the fallback those rules use too. The in-progress role is still a
    # role like any other - a policy can name it with --enter-role - it simply no
    # longer narrows this silently.
    my $working = 0;
    for my $type (qw(sow epic ticket)) {
        my $columns = eval { $tira->column_list( project => $root, type => $type ) } || [];
        my $records = eval { $tira->record_list( project => $root, type => $type ) } || [];
        my %ends = map { $_->{name} => 1 } grep { $_->{terminal} } @{$columns};
        $ends{done} = 1 if !keys %ends;
        my %here = map { $_->{name} => 1 }
          grep { !$_->{protected} && !$ends{ $_->{name} } } @{$columns};

        for my $record ( @{$records} ) {
            $working++, last if $here{ $record->{column} // '' };
        }
        last if $working;
    }
    return $working ? 1 : 0;
}
# Police keeps its state outside the project it watches, so that it can never
# become a second writer to the board - which is what destroyed this project's
# own board on the day the subsystem was designed.
# One directory per board, named for it, so two boards never write over each
# other - the rule _backup_home states forty lines below and this did not keep.
# It took the --project OPTION and called the answer 'here' when there was none.
# Police started from inside a project passes no --project, so every board
# worked that way shared a single store: the version each board last heard, the
# violation numbering, the escalation counts, the suspensions, and the bridge
# log they are written to. A board was never told about an upgrade because a
# different board had already been told about it.
# Refused rather than invented now. Every caller has a board to hand - police
# discovers one before it can watch anything - so there is no case where a name
# has to be made up, and inventing one is what made the sharing silent.
sub _police_store {
    my ($project) = @_;
    die "A police store has to belong to a board, and none was given\n"
      if !defined $project || $project !~ /\S/;
    my $home = $ENV{HOME} // File::Spec->tmpdir;
    my $slug = $project;
    $slug =~ s/[^A-Za-z0-9]+/-/g;
    $slug =~ s/\A-|-\z//g;
    return File::Spec->catdir( $home, '.tira-police', $slug );
}
1;
