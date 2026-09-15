package Tira::CLI::Police::World;

# The world police needs and the engine will not touch, lifted out of
# Tira::CLI::Police - TKT-1103, the same reason TKT-1043 lifted the due-job
# execution block into Tira::CLI::Police::Jobs: a 1153-line file (after
# TKT-1098/TKT-1100 already moved its POD out and added the policy.bridge
# singleton) stayed over Michael's 1000-line cap (TKT-1092) with this cluster
# still in it - what is running on this machine, which containers, which git
# branches and worktrees, what is unpushed, when the tree last changed. None
# of that is needed by any other command in Tira::CLI::Police, and it was the
# single largest cohesive concern left in the file (t/524's own exemption
# text named it: "the police pass and its bridge... rest is still one file").
#
# CALLED THROUGH A FORWARD OF THE SAME NAME in Tira::CLI::Police -
# police_world, _running_processes (Tira::CLI::Job::Monitor's own liveness
# check calls it directly), _running_containers and _unpushed_commits/
# _tree_changing_since (both called directly by their fully-qualified
# Tira::CLI::Police:: name from several existing tests, t/998/t/107). Every
# other helper here (_git_branches, _git_worktrees, _sandbox_clone_dirs) has
# no caller outside police_world itself, so it gets none - the same
# convention Tira::Tasklist's own purely-internal helpers already follow.
#
# police_world's own single external dependency on Tira::CLI::Police is
# _card_in_progress, which stays there (it is not part of the world scan -
# it reads the BOARD, not the machine) and is called by its fully-qualified
# name for the identical reason every lift in this codebase does that: an
# unqualified call would resolve to a same-named sub in THIS package at
# compile time, which does not exist, rather than reaching across to the one
# that does.

use strict;
use warnings;

use Cwd ();
use File::Spec ();
use Tira;

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
# Every immediate subdirectory of ~/Sandbox/<basename of $where>/, his own
# per-ticket clone convention (Q-140/Q-141, TKT-998). Something under there
# that is not a repository is simply skipped by _unpushed_commits's own
# guard, not treated as a fault - a stray file or an in-progress checkout is
# not this rule's business.
sub _sandbox_clone_dirs {
    my ($where) = @_;
    return () if !defined $where || $where eq '';
    ( my $trimmed = $where ) =~ s{/+\z}{};
    my $basename = ( File::Spec->splitdir($trimmed) )[-1];
    return () if !defined $basename || $basename eq '';
    my ($home) = ( $ENV{HOME} // '' ) =~ /\A([^\x00-\x1f\x7f]*)\z/;
    return () if !defined $home || $home eq '';
    my $sandbox = File::Spec->catdir( $home, 'Sandbox', $basename );
    return () if !-d $sandbox;
    opendir my $dh, $sandbox or return ();
    my @clones = grep { -d $_ }
      map { File::Spec->catdir( $sandbox, $_ ) }
      grep { !/\A\.\.?\z/ } readdir $dh;
    closedir $dh;
    return @clones;
}

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
sub police_world {
    require Tira::CLI::Backup;
    require Tira::CLI::Police;
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

    # His own working pattern (Q-140/Q-141, TKT-998): CODE stays a pristine
    # reference at $where, and actual work happens in per-ticket clones under
    # ~/Sandbox/<basename of $where>/. Watched the same way $where itself is -
    # every immediate subdirectory there, each asked for its own unpushed
    # commits and merged in, so a clone with work in progress is seen
    # regardless of which path happens to be the one declared repository.
    my @commits = @{ _unpushed_commits($where) };
    push @commits, @{ _unpushed_commits($_) } for _sandbox_clone_dirs($where);

    # TKT-1074, his own report through the developer-dashboard bridge:
    # git worktrees - sharing $where's own .git object store, not a separate
    # clone under ~/Sandbox/ - were collected into $world->{worktrees} below
    # for card-sandbox-missing's own use, but never asked for their unpushed
    # commits the way a sandbox clone already is. A commit sitting only on a
    # worktree branch was invisible to this rule. `git worktree list`
    # includes $where's own entry alongside every other worktree of the same
    # repository - Cwd::realpath compared so a symlinked or differently-
    # spelled $where does not admit that entry as though it were a second,
    # separate worktree, double-counting every one of $where's own unpushed
    # commits (already gathered directly, above). $where need not be the
    # entry git happens to list first - a project can declare a linked
    # worktree rather than the main checkout - so every entry is checked
    # against $where, not assumed to be at any particular position.
    my $where_real = eval { Cwd::realpath($where) };
    for my $worktree ( @{ _git_worktrees($where) } ) {
        my $worktree_real = eval { Cwd::realpath($worktree) };
        next if !defined $worktree_real;
        next if defined $where_real && $worktree_real eq $where_real;
        push @commits, @{ _unpushed_commits($worktree) };
    }

    my $world = {
        branches   => _git_branches($where),
        worktrees  => _git_worktrees($where),
        processes  => _running_processes(),
        containers => _running_containers(),
        commits    => \@commits,
    };
    $world->{unpushed_since} = @commits ? ( sort map { $_->{at} } @commits )[0] : undef;
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
      : Tira::CLI::Police::_card_in_progress( $args{tira}, $root );
    return $world;
}
1;

__END__

=head1 NAME

Tira::CLI::Police::World - what is true of this machine, for the police pass

=head1 DESCRIPTION

C<police_world> gathers what police needs to evaluate its rules and the
board's own engine will never touch: running processes, running containers,
git branches and worktrees for the project's declared (or guessed)
repository, unpushed commits across that repository and every per-ticket
sandbox clone beside it, when the working tree last changed, and when the
board was last backed up. Lifted out of L<Tira::CLI::Police> by TKT-1103.

=head1 CALL IT THROUGH TIRA::CLI::POLICE, NOT DIRECTLY

C<Tira::CLI::Police> is where every one of these lived before this lift,
and C<police_world> stays reachable at C<Tira::CLI::Police::police_world>
through a one-line forward - several existing tests and
L<Tira::CLI::Job::Monitor> already call it (and C<_running_processes>,
C<_running_containers>, C<_unpushed_commits>, C<_tree_changing_since>) by
that fully-qualified name, and the forward is what keeps them working
unchanged.

=head1 IF YOU EDIT THIS MODULE

C<police_world>'s own call to C<_card_in_progress> reaches across to
C<Tira::CLI::Police::_card_in_progress> by its fully-qualified name,
because that helper reads the BOARD rather than the machine and stayed
where it was - an unqualified call would resolve to a same-named sub in
THIS package at compile time, which does not exist, rather than reaching
the one that does. Any new call this module needs to make back into
C<Tira::CLI::Police> should be qualified the same way.

=cut
