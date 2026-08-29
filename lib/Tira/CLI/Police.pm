package Tira::CLI::Police;

# Police, the bridge, and the dev-report verb - moved out of Tira::CLI so that
# reading the CLI to change anything else no longer means reading it. The first
# slice moved 368 lines of world-scanning and violation-following; later slices
# brought the two police command bodies and the store and card-in-progress
# readers, and the module is 575 lines of subs today.
#
# The world scan is the bulk of it: what is running on this machine, which
# containers, which git branches and worktrees, what is unpushed, when the tree
# last changed. None of that is needed by any other command, and all of it was
# in the file every command had to be read through.
#
# WHAT STAYED IN Tira::CLI AND IS CALLED BY ITS FULL NAME HERE: the backup
# readers (_backup_home, _backup_store, _last_backup, _later_backup,
# _last_backup_commit), which the world scan reads but does not own; the process
# and container primitives (_processes_from, _processes_from_windows,
# _containers_from, _process_command, _reading), which are general; the git
# helpers _is_repository and _tracking_branch; _card_in_progress,
# _dashboard_hup_if_stale, _restart_if_updated, _tira_home and _utf8_bytes.
#
# Qualifying them is deliberate beyond necessity. A reader of this file can see
# at the call site that the helper lives in the index rather than here, which is
# the distinction the split exists to make; an import would have hidden exactly
# the fact worth showing.

use strict;
use warnings;

use Cwd ();
use File::Spec ();
use Tira;



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
    my $claim = police_claim_singleton( $store, %{ $option->{singleton} // {} } );
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
            police_release_singleton( $store, %{ $option->{singleton} // {} } );
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
            print {*STDERR} map { "$_\n" } @{ $result->{terminal} };
        }
        # Into the code that is installed, between rounds.
        #
        # The machinery has existed since the dashboard needed it and nothing
        # here ever called it, so a police left running through a release kept
        # the rulebook it started with: rules that shipped since were not
        # evaluated, wording that had been corrected was still printed, and it
        # said nothing about either - a watcher reading old rules looks exactly
        # like a watcher reading new ones. Reported by the owner on 2026-08-15,
        # and measured on this project's own board an hour later, where a fix
        # that had shipped, passed its gate and reached origin went on being
        # contradicted by the police still running the previous version.
        #
        # Between rounds, never during a pass: police writes the bridge and the
        # enforcement ledger, and a pass cut in half would leave a violation
        # counted and unsaid, or said and uncounted.
        #
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
    return { rounds => $done };
}
# The world police needs and the engine will not touch. Gathered here, handed
# in as plain facts, so that Tira itself still invokes no shell.
#
# It used to return five empty lists and nothing else. Six declared rules read
# this - leftover-process, leftover-container, commit-without-card,
# work-without-card, unpushed-work and board-unbacked - and every one of them
# evaluated against nothing and stayed silent. A rule that is silent because it
# was shown nothing looks exactly like a rule being obeyed, which is the very
# sentence police prints to the owner when a rule is missing entirely. Found on
# 2026-08-12, when board-unbacked said the board had never been backed up while
# the backups the push gate writes sat in ~/.tira-backups.
sub police_world {
    require Tira::CLI::Backup;
    my (%args) = @_;
    my $root = $args{project};

    # The repository the project declared, when it declared one. Police used to
    # run git in the directory holding the board, which is the right guess only
    # when the two are the same place - and on a board that sits outside its
    # repository every question came back empty, so card-sandbox-missing
    # reported every card as missing a branch and a work tree that both existed.
    #
    # Declared beats guessed and nothing else changes: a board that does sit
    # inside its repository still finds it without saying anything.
    my $declared = eval {
        Tira->new->project_show( project => $root )->{repo};
    };
    my $where =
        ( defined $declared && $declared ne '' && -d $declared ) ? $declared
      : ( defined $root && -d $root ) ? $root
      :                                 undef;

    my $world = {
        branches   => _git_branches($where),
        worktrees  => _git_worktrees($where),
        processes  => _running_processes(),
        containers => _running_containers(),
        commits    => _unpushed_commits($where),
    };
    $world->{unpushed_since} = @{ $world->{commits} } ? $world->{commits}[-1]{at} : undef;
    $world->{working_since} = _tree_changing_since($where);
    # The board's own repository first, because that is what tira.backup writes
    # and what any board can have. The old answer was a directory of stamps
    # under the home directory that only one repository on earth wrote to, so
    # every other board was told it had never been backed up and had no way to
    # change that. It is still read, so a board backed up by the old tool is not
    # suddenly told it never was.
    #
    # Asked about the board, not about $where. Every other question here is
    # about the repository the work happens in; this one is about the board,
    # and tira.backup, tira.backup.restore and tira.backup.export all resolve
    # the store from the board root. Asking it with $where meant that a project
    # which declared a repository had its backups looked for inside the code -
    # where there are none - and board-unbacked told it that it had never been
    # backed up, permanently, whatever anybody did.
    #
    # developer-dashboard reported exactly that on 2026-08-15: the rule raised
    # at 07:55 and escalated twice while the board was backed up three times in
    # between, against a seven-day age. One variable was answering two
    # questions, which are the same place until somebody says otherwise.
    #
    # And both mechanisms, not the first one that answers. `//` meant "the
    # commit, or the directories if there is no commit", when the question is
    # when this board was last backed up by anything at all. tools/board-backup
    # writes the directories on every push and tira.backup writes the commit, so
    # a board the gate had backed up 481 times was told its last backup was the
    # one somebody ran by hand six hours earlier - and advised to run that same
    # command. The later of the two is the answer.
    $world->{backed_up_at} = Tira::CLI::Backup::_later_backup(
        Tira::CLI::Backup::_last_backup_commit( Tira::CLI::Backup::_backup_store($root) ),
        Tira::CLI::Backup::_last_backup( $args{backups} // Tira::CLI::Backup::_backup_home($root) ),
    );
    $world->{card_in_progress} = exists $args{card_in_progress}
      ? $args{card_in_progress}
      : _card_in_progress( $args{tira}, $root );
    return $world;
}
# The claim: read whoever was there before, kill them if they are still
# alive, then write our own pid over theirs. pid/alive/kill are all
# injectable - the same shape leave/restarter/sleeper already use in
# _police_follow - so this is provable without spawning or signalling a
# real OS process. TKT-492.
sub police_claim_singleton {
    my ( $store, %opts ) = @_;
    File::Path::make_path($store) if !-d $store;
    my $path = police_singleton_path($store);
    my $my_pid = $opts{pid} // $$;
    my $alive = $opts{alive} || sub { return kill 0, $_[0] };
    my $kill_previous = $opts{kill} || sub { kill 'TERM', $_[0] };

    my $killed;
    if ( open my $fh, '<', $path ) {
        my $previous = do { local $/; <$fh> };
        close $fh;
        $previous =~ s/\s+//g;
        if ( length $previous && $previous ne $my_pid && $alive->($previous) ) {
            $kill_previous->($previous);
            $killed = $previous;
        }
    }
    open my $fh, '>', $path or die "Cannot claim the police singleton at '$path': $!\n";
    print {$fh} $my_pid;
    close $fh;
    return { claimed => $my_pid, killed => $killed };
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
sub police_release_singleton {
    my ( $store, %opts ) = @_;
    my $path = police_singleton_path($store);
    my $remove = $opts{unlink} || sub { unlink $_[0] };
    $remove->($path);
    return;
}
# Where the singleton claim lives - beside the enforcement ledger itself,
# since both are per-store, not per-project.
sub police_singleton_path {
    my ($store) = @_;
    return File::Spec->catfile( $store, '.police.pid' );
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
sub _running_containers {
    require Tira::CLI::Serve;
    return Tira::CLI::Serve::_containers_from(
        Tira::CLI::Serve::_reading( 'docker', 'ps', '--format', '{{.Names}}\t{{.CreatedAt}}' ) );
}
# The process table, with when each one started, because every rule about a
# leftover asks how long it has been there rather than whether it exists.
sub _running_processes {
    require Tira::CLI::Serve;
    return Tira::CLI::Serve::_processes_from_windows( Tira::CLI::Serve::_reading( Tira::CLI::Serve::_process_command($Tira::CLI::WINDOWS) ) ) if $Tira::CLI::WINDOWS;
    return Tira::CLI::Serve::_processes_from( Tira::CLI::Serve::_reading( Tira::CLI::Serve::_process_command($Tira::CLI::WINDOWS) ) );
}
# -C rather than chdir, so the whole of this module stays in one directory and
# nothing has to be put back afterwards.
sub _git_branches {
    require Tira::CLI::Serve;
    my ($where) = @_;
    return [] if !Tira::CLI::Serve::_is_repository($where);
    return Tira::CLI::Serve::_reading( 'git', '-C', $where, 'branch', '--format=%(refname:short)' );
}
sub _git_worktrees {
    require Tira::CLI::Serve;
    my ($where) = @_;
    return [] if !Tira::CLI::Serve::_is_repository($where);
    return [ map { s/\Aworktree\s+//r } grep { /\Aworktree\s/ }
          @{ Tira::CLI::Serve::_reading( 'git', '-C', $where, 'worktree', 'list', '--porcelain' ) } ];
}
# Commits this branch has and the branch it is pushed to does not. Nowhere to
# have been pushed means nothing is sitting unpushed - a branch nobody has ever
# pushed is not the same as work left waiting.
sub _unpushed_commits {
    require Tira::CLI::Serve;
    my ($where) = @_;
    return [] if !Tira::CLI::Serve::_is_repository($where);
    my ($branch) = @{ Tira::CLI::Serve::_reading( 'git', '-C', $where, 'rev-parse', '--abbrev-ref', 'HEAD' ) };
    return [] if !defined $branch || $branch eq '' || $branch eq 'HEAD';
    my $upstream = Tira::CLI::Serve::_tracking_branch( $where, $branch );
    return [] if !defined $upstream || $upstream eq '';
    my $lines = Tira::CLI::Serve::_reading( 'git', '-C', $where, 'log', '--format=%H%x09%cI%x09%s', "$upstream..HEAD" );
    return [ map { my ( $sha, $at, $subject ) = split /\t/, $_, 3;
            { sha => $sha, at => $at, subject => $subject // '' } } @{$lines} ];
}
# When the working tree last changed, which is what work-without-card means by
# work. A clean tree is not work in progress, so it answers with nothing.
sub _tree_changing_since {
    require Tira::CLI::Serve;
    my ($where) = @_;
    return undef if !Tira::CLI::Serve::_is_repository($where);
    my $changed = Tira::CLI::Serve::_reading( 'git', '-C', $where, 'status', '--porcelain' );
    return undef if !@{$changed};
    my $oldest;
    for my $line ( @{$changed} ) {
        next if $line !~ /\A.{3}(.+)\z/;
        my $path = File::Spec->catfile( $where, $1 );
        next if !-e $path;
        my $when = ( stat $path )[9];
        $oldest = $when if !defined $oldest || $when < $oldest;
    }
    return undef if !defined $oldest;
    my @when = gmtime $oldest;
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
      $when[5] + 1900, $when[4] + 1, @when[ 3, 2, 1, 0 ];
}
# The two command bodies, lifted out of Tira::CLI::_invoke rather than out of
# its helpers - the first piece of what TKT-607 calls the hard half. _invoke was
# 1,294 lines, and only about fifty of them are the dispatcher; the rest are
# per-command blocks like these two, each of which belongs with the concern it
# is about rather than in the file every other command has to be read through.
#
# They take \%args rather than reading a lexical, which is the only thing that
# had to change: inside _invoke they closed over %args, $option and $command,
# and here those arrive as arguments. Nothing else in either block moved.

# When the last pass ran, and whether that is recent enough to trust.
#
# tira.police.outstanding answers what is outstanding AS OF THE LAST PASS, and
# on a clean board that answer is an empty list. On a board whose bridge stopped
# eleven hours ago it is also an empty list - the same bytes, with no field to
# compare. Measured on zenandi, 2026-08-29: a pass at 03:38:41 read at 14:41:50,
# unchanged, while the board reported itself clean all day and a card-duration
# policy sat an hour past its age in that silence.
#
# WHY A SECOND COMMAND RATHER THAN A RICHER PAYLOAD. Q-096, answered by the owner
# and marked ok: "Keep the bare list and add a separate command for freshness
# [...] Nothing breaks anywhere; the cost is a second command to remember and a
# question answered somewhere other than where it is asked." Two other projects
# pipe and index that payload in the loop they use to decide whether work is
# finished, and docs/commands.md promises it stays a list. TKT-354 chose
# one-shape-always for tira.next in 3.48 and that precedent does not transfer:
# that command had no documented consumers outside this board.
#
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
    return [ 'last pass ' . $answer->{taken_at}
          . ' - UNREADABLE, so nothing can be judged from it and an empty answer'
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
        $tira->bridge_write( store => $store, project => $watching,
            violations => $result->{violations}, settled => $result->{settled},
            upgraded => $result->{upgraded} )
          if $result->{watching};
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
    #
    # DECIDED, not deferred. This comment used to say the list stays because
    # "TKT-354 is already open about tira.next answering with a dict when work
    # waits and a list when it does not - the same fault from the other side".
    # TKT-354 closed in 3.48 and chose the OPPOSITE: one shape always, a hash,
    # over documenting the inconsistency. So this cited a card that had decided
    # against it, for a year of releases, and nobody noticed because a deferral
    # reads like a reason.
    #
    # Q-096 settled it here, and reached the same conclusion for a current
    # reason: "Keep the bare list and add a separate command for freshness [...]
    # Nothing breaks anywhere; the cost is a second command to remember and a
    # question answered somewhere other than where it is asked." tira.next had
    # no documented consumers outside this board; this payload has two, and
    # docs/commands.md promises them a list. That command is police_freshness
    # above, and the cost he named is paid by the warning below, which names it.
    # TKT-684.
    #
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
        #
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
            interval => $option->{interval}, sleeper => $option->{sleeper} )
          if !$option->{once};
        return { streamed => scalar @{$backlog} };
    }

    # Before anything is reported: what to hand the agent. Police watching a
    # board nobody has set up finds nothing, and that silence looks exactly
    # like compliance - so the owner gets something to copy across rather
    # than writing the instructions himself every time. Printed on every
    # run, because remembering which run was the first is the sort of thing
    # he should not have to do.
    #
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
    print {*STDERR} map { "$_\n" } @{ $result->{terminal} };
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
    #
    # This counted a card as being worked only if it sat in the single column
    # named by the in-progress role, when a board declared one. On this project's
    # own board - in-progress=implement, five columns work happens in - that left
    # tests-red, verify, document and push reading as nobody working, and
    # work-without-card raised VIO-0013 to CRITICAL five times while a card sat
    # in verify with its suite running.
    #
    # A setting that names one column stops covering the board the moment work
    # happens in another, which is the fault column-unwatched reports for
    # policies. The role was accurate when it was set; the board grew.
    #
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
#
# It took the --project OPTION and called the answer 'here' when there was none.
# Police started from inside a project passes no --project, so every board
# worked that way shared a single store: the version each board last heard, the
# violation numbering, the escalation counts, the suspensions, and the bridge
# log they are written to. A board was never told about an upgrade because a
# different board had already been told about it.
#
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

__END__

=head1 NAME

Tira::CLI::Police - the police pass, the bridge, and the world it scans

=head1 DESCRIPTION

C<police_world> gathers what is true of this machine - running processes and
containers, git branches, worktrees, unpushed commits, when the tree last
changed - and C<police_pass> in L<Tira> judges the board against it.
C<police_follow> and C<bridge_follow> are the two loops in this module.
C<report_to_tira> is the body behind C<tira.dev.found.bug_or_improvement>.

=head2 Which of these runs a pass

Only three call C<police_pass>, and the difference is the whole reason
C<--fresh> exists:

=over

=item * C<police_follow> - the C<d2 tira.police> watch loop, on every tick.

=item * C<police_run> - a single pass on demand.

=item * C<police_outstanding> - B<only> when C<--fresh> is given. Without it
the command reports what the last pass wrote, however old that is.

=back

C<bridge_follow> never runs one. It streams what a pass has already recorded,
so a board whose watcher has stopped keeps answering from the last pass and the
bridge cannot tell. That is not a defect in the bridge - one process writes to a
project, and a reader that started passes of its own would be a second writer -
but it does mean the loop that looks most like it is watching the board is the
one that never judges it.

Said here because it was written down nowhere outside this source until 4.81,
and two cards were raised by somebody who could not find it out. TKT-745.

They lived in C<Tira::CLI> until 4.74. C<Tira::CLI> now loads this module with
C<require> at each point one of those verbs is entered, so a CLI call that never
polices anything never compiles the world scan.

=head2 Why each entry says require

There are five entries into this module from C<Tira::CLI> and each carries its
own C<require>. C<require> is idempotent - it consults C<%INC> and returns - so
the repetition costs nothing at runtime, and it buys the property that matters
in an index: a reader at any one of those call sites can see where control is
going without having to know that an earlier branch was taken first.

=head2 The singleton

C<police_claim_singleton>, C<police_release_singleton>, C<police_singleton_path>
and C<police_goodbye> are the lock that stops two police passes running against
one board at once, and the farewell the second one prints. They move together
because they are one mechanism.

=head2 How this module is loaded

C<Tira::CLI> pulls this in with C<require> at the point one of its verbs runs,
so a command that never needs it never compiles it. It calls into L<Tira::CLI::Backup> and L<Tira::CLI::Serve>, and asks for
that the same way - inside the sub that needs it, not at the top of this
file. A C<use> there is correct and turns a lazy chain eager, which is how
C<tira.next> came to compile four modules for the sake of one helper for the
first hour after the split.

=head1 SEE ALSO

L<Tira::CLI>, L<Tira::CLI::Backup>

=cut
