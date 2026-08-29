package Tira::CLI::Backup;

# The four backup verbs - backup, backup.restore, backup.export, backup.import -
# moved out of Tira::CLI so that reading the CLI to change anything else no
# longer means reading these.
#
# They were four consecutive special-cases in _invoke and 249 lines of bodies
# sitting in the middle of the file. Tira::CLI now names the concern once and
# requires this module when one of those four commands is actually run.
#
# WHAT STAYED BEHIND, AND WHY IT IS CALLED BY ITS FULL NAME HERE:
# _backup_store and _last_backup_commit answer questions other parts of the CLI
# ask too - the status output at Tira::CLI's own _invoke reads the last backup
# commit, and two test files call _last_backup_commit by name - so moving them
# would have changed a surface this card is not allowed to change.
# _program_exists, _reading, _running and _running_quietly are general process
# helpers with nothing to do with backups.
#
# $Tira::CLI::SCHEMA_VERSION likewise stays where it is: it is the board's
# schema, not the backup format's, and restore only happens to be its loudest
# reader.

use strict;
use warnings;

use File::Path ();
use File::Spec ();
use File::Temp ();
use Tira;

# An identity given on the command rather than written into the repository. A
# backup must not depend on whoever runs it having configured git, and must not
# quietly change what their own git would do. It was a file-scoped lexical in
# Tira::CLI and had exactly one reader, the commit below, so it came with the
# concern rather than being reached for across a package boundary.
my @BACKUP_AUTHOR = (
    '-c', 'user.name=Tira', '-c', 'user.email=tira@localhost',
    '-c', 'commit.gpgsign=false',
);

# A backup is a commit. His design, and the right one: the board is a directory
# of files, git is what keeps a directory of files, and a repository with no
# remote cannot fail because somebody else's machine is down.
#
# Nothing exists until the first backup, so a board that leaves the policy out
# is untouched on disk - and nobody has to run git init to obey a rule, because
# a command that works only after an invisible setup step is one that leaves the
# rule firing anyway.
sub backup {
    my ( $tira, $args ) = @_;
    my $root = $tira->discover_project( %{$args} );
    my $store = Tira::CLI::_backup_store($root);

    die "Tira needs git to back a board up, and it is not installed here\n"
      if !Tira::CLI::_program_exists('git');

    my $created = -d File::Spec->catdir( $store, '.git' ) ? 0 : 1;
    if ($created) {
        Tira::CLI::_running( 'git', '-C', $store, 'init', '--quiet' )
          or die "Could not start a repository for this board at $store\n";
    }

    # What a backup leaves out, checked on every run rather than at creation.
    #
    # The lock is about right now rather than about the board, and a restored
    # lock is a wedged board. A session is the server side of somebody's
    # sign-in: a restored one hands over an identity, which is worse than a
    # stale lock stopping one write. Neither is state worth having back.
    #
    # Written every time because it used to be written only when the store was
    # created, so a board made before a line was added here would never see it -
    # and every board that exists today was made before this one.
    #
    # Sessions are also rewritten whenever anybody uses the board, so while they
    # were tracked there was always something pending and tira.backup reported
    # changed: 1 on runs seconds apart with nothing touched. That is what he
    # noticed, and why "is this board already backed up" had no answer.
    {
        my $ignore = File::Spec->catfile( $store, '.gitignore' );
        my %already;
        if ( open my $read, '<', $ignore ) {
            while ( my $line = <$read> ) { chomp $line; $already{$line} = 1 }
            close $read;
        }
        my @missing = grep { !$already{$_} } ( '.lock', 'sessions/' );
        if (@missing) {
            open my $handle, '>>', $ignore or die "Could not write $ignore: $!\n";
            print {$handle} "$_\n" for @missing;
            close $handle;

            # Ignoring a path git is already tracking changes nothing, so a
            # board that has been backed up before has to be told to stop
            # carrying them. Only the index: what the history already holds
            # stays there, because rewriting the history of a backup is a worse
            # thing to own than the tidiness it buys.
            # _running, not _running_quietly. git's own --quiet and
            # --ignore-unmatch already keep it silent, and _running_quietly was
            # measured to silence everything this process prints afterwards when
            # standard output is an in-memory handle - which is how every test
            # in this suite captures output. Raised separately; not worked
            # around here, because the plain call is also the simpler one.
            Tira::CLI::_running( 'git', '-C', $store, 'rm', '-r', '--cached', '--quiet',
                '--ignore-unmatch', 'sessions' );
        }
    }

    Tira::CLI::_running( 'git', '-C', $store, 'add', '--all' )
      or die "Could not read the board into the backup\n";

    my $pending = Tira::CLI::_reading( 'git', '-C', $store, 'status', '--porcelain' );
    my $changed = @{$pending} ? 1 : 0;

    if ($changed) {
        my $count = scalar @{$pending};
        my $message = $created
          ? 'The board as it stands, backed up for the first time'
          : "$count " . ( $count == 1 ? 'thing' : 'things' ) . ' changed since the last backup';
        Tira::CLI::_running( 'git', '-C', $store, @BACKUP_AUTHOR, 'commit', '--quiet', '-m', $message )
          or die "Could not record the backup\n";
    }

    my ($commit) = @{ Tira::CLI::_reading( 'git', '-C', $store, 'rev-parse', '--short', 'HEAD' ) };
    return {
        commit  => $commit,
        at      => Tira::CLI::_last_backup_commit($store),
        created => $created,
        changed => $changed,
        store   => $store,
        message => $changed
          ? 'The board is backed up.'
          : 'Nothing has changed since the last backup, so it still stands.',
    };
}

# Putting a board back. His design: git reset --hard, so a restore is a restore
# and anything done since the backup is gone.
#
# Which is exactly why it says what it is about to discard first and does
# nothing until that is agreed to. This is the only command in Tira that can
# lose work, and a command that destroys in silence is one people either stop
# running or run without reading.
sub backup_restore {
    my ( $tira, $args, $option ) = @_;
    my $root = $tira->discover_project( %{$args} );
    my $store = Tira::CLI::_backup_store($root);

    die "Tira needs git to restore a board, and it is not installed here\n"
      if !Tira::CLI::_program_exists('git');
    die "This board has never been backed up, so there is nothing to restore it to.\n"
      . "Make one first: d2 tira.backup\n"
      if !defined Tira::CLI::_last_backup_commit($store);

    # What would be lost, read before anything is touched. Named rather than
    # counted: "3 files would be discarded" tells nobody whether it matters.
    my $changed = Tira::CLI::_reading( 'git', '-C', $store, 'status', '--porcelain' );
    my @losing = map { s/\A.{3}//r } @{$changed};

    if ( !$option->{yes} ) {

        # Printed rather than thrown, because a refusal is only useful if it can
        # be read. A structured error carries one string, and a multi-line
        # warning inside one arrives as literal backslash-n on the terminal -
        # which is how the one command that can destroy a board ends up with a
        # warning nobody reads.
        print {*STDERR} "Restoring puts this board back to its last backup and discards\n"
          . "what has happened since. That is:\n\n";
        print {*STDERR} @losing
          ? join( '', map { "  $_\n" } @losing )
          : "  nothing - the board is exactly as it was backed up\n";
        print {*STDERR} "\nRun it again with --yes if that is what you want.\n\n";
        die "Nothing was restored, because --yes was not given\n";
    }

    Tira::CLI::_running( 'git', '-C', $store, 'reset', '--hard', 'HEAD' )
      or die "Could not put the board back\n";

    # A file added since the backup is untracked, so reset leaves it exactly
    # where it was - and a card raised since would survive a restore that
    # reported success. Cleaning is the half of "put it back" that reset alone
    # does not do.
    Tira::CLI::_running( 'git', '-C', $store, 'clean', '--force', '-d', '--quiet' )
      or die "Could not clear what was added since the backup\n";

    my ($commit) = @{ Tira::CLI::_reading( 'git', '-C', $store, 'rev-parse', '--short', 'HEAD' ) };
    return {
        commit    => $commit,
        at        => Tira::CLI::_last_backup_commit($store),
        discarded => \@losing,
        store     => $store,
        message   => 'The board is back as it was when it was last backed up.',
    };
}

# Getting a backup off the machine. The repository lives inside the board's own
# storage, so it survives a bad edit and not a lost disk - and a bundle is one
# file holding the whole history, kept wherever the owner keeps things.
sub backup_export {
    my ( $tira, $args, $option ) = @_;
    my $root  = $tira->discover_project( %{$args} );
    my $store = Tira::CLI::_backup_store($root);
    my $file  = $option->{file}
      or die "Where should the bundle go? Name it: --file board.bundle\n";

    die "Tira needs git to export a backup, and it is not installed here\n"
      if !Tira::CLI::_program_exists('git');
    die "This board has never been backed up, so there is nothing to export.\n"
      . "Make a backup first: d2 tira.backup\n"
      if !defined Tira::CLI::_last_backup_commit($store);

    Tira::CLI::_running( 'git', '-C', $store, 'bundle', 'create', $file, '--all' )
      or die "Could not write the bundle to $file\n";

    return {
        file    => $file,
        at      => Tira::CLI::_last_backup_commit($store),
        message => "The board is in $file. Keep it somewhere the board is not.",
    };
}

# And bringing one back. The folder becomes what the bundle holds - his words:
# git reset --hard - so this can lose work exactly as a restore can, and says
# what it would discard before it does anything.
sub backup_import {
    my ( $tira, $args, $option ) = @_;
    my $file = $option->{file}
      or die "Which bundle? Name it: --file board.bundle\n";
    die "There is no bundle at $file\n" if !-f $file;

    die "Tira needs git to import a backup, and it is not installed here\n"
      if !Tira::CLI::_program_exists('git');
    # Verified in a repository of its own, because git will not read a bundle
    # from outside one - and the destination must not be touched until the
    # bundle is known to be good, or a refusal leaves a half-made board behind.
    require File::Temp;
    my $scratch = File::Temp::tempdir( CLEANUP => 1 );
    Tira::CLI::_running( 'git', '-C', $scratch, 'init', '--quiet' )
      or die "Could not check the bundle: no scratch repository\n";
    Tira::CLI::_running_quietly( 'git', '-C', $scratch, 'bundle', 'verify', $file )
      or die "$file is not a bundle git can read\n";

    # Claimed rather than read out of the bundle, because reading it means
    # unpacking it first - and unpacking a bundle from a newer Tira is the thing
    # being refused. The claim is what an exporter of a later release would
    # write beside it.
    my $claimed = $option->{claiming_schema};
    die "That bundle was made by a newer Tira (schema $claimed, this one reads "
      . "$Tira::CLI::SCHEMA_VERSION). Upgrade Tira and import it again.\n"
      if defined $claimed && $claimed > $Tira::CLI::SCHEMA_VERSION;

    # Where it is going, named as a folder rather than selected as a board.
    # discover_project would walk upwards and find somebody else's, so the
    # folder is taken as given: importing is how a board comes into existence
    # somewhere, not something done to one that is found. That is why this
    # takes --dir, like creating a board does, while everything that works on
    # an existing board is told which one in the environment. TKT-250.
    my $where = $option->{dir} // $args->{project}
      or die "Where should the board go? Name the folder it should be made in.\n";
    my $store = Tira::CLI::_backup_store($where);

    my $existing = -d File::Spec->catdir( $store, '.git' ) ? 1 : 0;
    if ( $existing && !$option->{yes} ) {
        my @losing = map { s/\A.{3}//r }
          @{ Tira::CLI::_reading( 'git', '-C', $store, 'status', '--porcelain' ) };
        print {*STDERR} "There is already a board here, and importing replaces it\n"
          . "with what the bundle holds. Uncommitted work here:\n\n";
        print {*STDERR} @losing
          ? join( '', map { "  $_\n" } @losing )
          : "  none, but every card in this board would be replaced\n";
        print {*STDERR} "\nRun it again with --yes if that is what you want.\n\n";
        die "Nothing was imported, because --yes was not given\n";
    }

    File::Path::make_path($store) if !-d $store;
    if ( !$existing ) {
        Tira::CLI::_running( 'git', '-C', $store, 'init', '--quiet' )
          or die "Could not start a repository at $store\n";
    }
    Tira::CLI::_running( 'git', '-C', $store, 'fetch', '--quiet', $file, 'HEAD' )
      or die "Could not read the bundle into the board\n";
    Tira::CLI::_running( 'git', '-C', $store, 'reset', '--hard', 'FETCH_HEAD' )
      or die "Could not lay the board out from the bundle\n";
    Tira::CLI::_running( 'git', '-C', $store, 'clean', '--force', '-d', '--quiet' )
      or die "Could not clear what was here before the import\n";

    my ($commit) = @{ Tira::CLI::_reading( 'git', '-C', $store, 'rev-parse', '--short', 'HEAD' ) };
    return {
        commit  => $commit,
        at      => Tira::CLI::_last_backup_commit($store),
        store   => $store,
        message => 'The board is here, as it was when that bundle was made.',
    };
}
1;

__END__

=head1 NAME

Tira::CLI::Backup - the backup, restore, export and import verbs

=head1 DESCRIPTION

C<backup>, C<backup_restore>, C<backup_export> and C<backup_import> are the
bodies behind C<tira.backup>, C<tira.backup.restore>, C<tira.backup.export> and
C<tira.backup.import>. They lived in C<Tira::CLI> until 4.74, where they were
four consecutive special-cases in C<_invoke> and 249 lines of bodies in the
middle of a 6,048-line file.

C<Tira::CLI> names the concern once and loads this module with C<require> when
one of the four commands is actually run, so a CLI call that never backs
anything up never compiles any of it.

=head2 What stayed in Tira::CLI

C<_backup_store> and C<_last_backup_commit> answer questions other parts of the
CLI ask - the status output reads the last backup commit, and two test files
call C<Tira::CLI::_last_backup_commit> by name. Moving them would have changed a
surface this refactor is not allowed to change, so they are called here by their
full names.

C<_program_exists>, C<_reading>, C<_running> and C<_running_quietly> are general
process helpers with nothing to do with backups.

C<$Tira::CLI::SCHEMA_VERSION> is the board's schema version, not the backup
format's; restore is only its loudest reader.

=head1 SEE ALSO

L<Tira::CLI>

=cut
