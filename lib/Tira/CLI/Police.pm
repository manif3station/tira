package Tira::CLI::Police;

# Police, the bridge, and the dev-report verb - moved out of Tira::CLI so that
# reading the CLI to change anything else no longer means reading 368 lines of
# world-scanning and violation-following.
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

# The world scan reads the machine through Tira::CLI::Serve's process and
# container helpers. This module is itself only loaded when a police verb runs,
# so asking for Serve here costs an ordinary card command nothing - and a `use`
# rather than a scattered `require` says plainly that police cannot work
# without it, which a lazy load would have left a reader to discover.
use Tira::CLI::Serve ();

sub police_follow {
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
    my $restarter = $option->{restarter} || \&_restart_into;
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
    $world->{backed_up_at} = Tira::CLI::_later_backup(
        Tira::CLI::_last_backup_commit( Tira::CLI::_backup_store($root) ),
        Tira::CLI::_last_backup( $args{backups} // Tira::CLI::_backup_home($root) ),
    );
    $world->{card_in_progress} = exists $args{card_in_progress}
      ? $args{card_in_progress}
      : Tira::CLI::_card_in_progress( $args{tira}, $root );
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
    return Tira::CLI::Serve::_containers_from(
        Tira::CLI::_reading( 'docker', 'ps', '--format', '{{.Names}}\t{{.CreatedAt}}' ) );
}
# The process table, with when each one started, because every rule about a
# leftover asks how long it has been there rather than whether it exists.
sub _running_processes {
    return Tira::CLI::Serve::_processes_from_windows( Tira::CLI::_reading( Tira::CLI::Serve::_process_command($Tira::CLI::WINDOWS) ) ) if $Tira::CLI::WINDOWS;
    return Tira::CLI::Serve::_processes_from( Tira::CLI::_reading( Tira::CLI::Serve::_process_command($Tira::CLI::WINDOWS) ) );
}
# -C rather than chdir, so the whole of this module stays in one directory and
# nothing has to be put back afterwards.
sub _git_branches {
    my ($where) = @_;
    return [] if !Tira::CLI::_is_repository($where);
    return Tira::CLI::_reading( 'git', '-C', $where, 'branch', '--format=%(refname:short)' );
}
sub _git_worktrees {
    my ($where) = @_;
    return [] if !Tira::CLI::_is_repository($where);
    return [ map { s/\Aworktree\s+//r } grep { /\Aworktree\s/ }
          @{ Tira::CLI::_reading( 'git', '-C', $where, 'worktree', 'list', '--porcelain' ) } ];
}
# Commits this branch has and the branch it is pushed to does not. Nowhere to
# have been pushed means nothing is sitting unpushed - a branch nobody has ever
# pushed is not the same as work left waiting.
sub _unpushed_commits {
    my ($where) = @_;
    return [] if !Tira::CLI::_is_repository($where);
    my ($branch) = @{ Tira::CLI::_reading( 'git', '-C', $where, 'rev-parse', '--abbrev-ref', 'HEAD' ) };
    return [] if !defined $branch || $branch eq '' || $branch eq 'HEAD';
    my $upstream = Tira::CLI::_tracking_branch( $where, $branch );
    return [] if !defined $upstream || $upstream eq '';
    my $lines = Tira::CLI::_reading( 'git', '-C', $where, 'log', '--format=%H%x09%cI%x09%s', "$upstream..HEAD" );
    return [ map { my ( $sha, $at, $subject ) = split /\t/, $_, 3;
            { sha => $sha, at => $at, subject => $subject // '' } } @{$lines} ];
}
# When the working tree last changed, which is what work-without-card means by
# work. A clean tree is not work in progress, so it answers with nothing.
sub _tree_changing_since {
    my ($where) = @_;
    return undef if !Tira::CLI::_is_repository($where);
    my $changed = Tira::CLI::_reading( 'git', '-C', $where, 'status', '--porcelain' );
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
1;

__END__

=head1 NAME

Tira::CLI::Police - the police pass, the bridge, and the world it scans

=head1 DESCRIPTION

C<police_world> gathers what is true of this machine - running processes and
containers, git branches, worktrees, unpushed commits, when the tree last
changed - and C<police_pass> in L<Tira> judges the board against it.
C<police_follow> and C<bridge_follow> are the two loops that keep doing so.
C<report_to_tira> is the body behind C<tira.dev.found.bug_or_improvement>.

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

=head1 SEE ALSO

L<Tira::CLI>, L<Tira::CLI::Backup>

=cut
