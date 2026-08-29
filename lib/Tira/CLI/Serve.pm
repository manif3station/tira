package Tira::CLI::Serve;

# Everything about the machine a board is served on: which process is listening,
# what is running, whether the code on disk moved under a live dashboard, and
# how to hand over to a newer version without dropping a request.
#
# It came out of Tira::CLI with TKT-607. None of it is needed by a command that
# only reads or writes a card, and all of it was in the file every such command
# had to be read through.
#
# THE PROCESS TABLE READERS ARE HERE because the police world scan is their
# largest reader but not their owner - Tira::CLI::Police calls them by their
# full names, the same way it calls the backup readers that stayed in the index.
# A helper belongs where its subject is, not where its busiest caller is.
#
# WHAT STAYED IN Tira::CLI: _command_of_pid, _parent_of_pid, _entrypoint_for,
# _version_on_disk and _dashboard_hup_mark_path, which answer questions about
# this installation rather than about the machine.

use strict;
use warnings;

use Cwd ();
use Digest::SHA ();
use File::Basename ();
use File::Spec ();
use Tira;

# Which process is holding a port, asked of the kernel rather than of a file
# somebody wrote earlier. Michael's own point on TKT-565: "Could that be more
# reliable to find the pid on demand by checking which is the master process
# by the port number?" - and it is, because a pidfile goes stale, survives a
# crash, and can name a pid the machine has since reused, while a listening
# socket is the truth at the moment it is asked.
#
# Read straight out of /proc, so Tira still invokes no shell: the port's
# listening socket gives an inode in /proc/net/tcp, and the process holding
# it is the one with that inode among its open descriptors. Anywhere without
# /proc this answers undef, which the caller treats as "no board found" and
# refuses on - the same way it treats every other uncertainty.
sub _listening_pid {
    my ( $port, %opts ) = @_;
    return undef if !defined $port || $port !~ /\A[0-9]+\z/;
    my $proc = $opts{proc} // '/proc';
    my $hex = sprintf '%04X', $port;

    my %inode;
    for my $table (qw(net/tcp net/tcp6)) {
        open my $fh, '<', File::Spec->catfile( $proc, $table ) or next;
        while ( my $line = <$fh> ) {

            # local_address is host:port in hex, and 0A is LISTEN. Anything
            # else on the same port is a connection to it, not the server.
            # After the 0A come tx:rx, tr:when, retrnsmt, uid and timeout
            # before the inode. Counting one field short here captured the
            # timeout - always 0 - and matched nothing, which looked exactly
            # like "no board is listening".
            next if $line !~ /\A\s*\d+:\s+\S+:$hex\s+\S+\s+0A\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)/;
            $inode{$1} = 1;
        }
        close $fh;
    }
    return undef if !%inode;

    opendir my $dh, $proc or return undef;
    my @pids = sort { $a <=> $b } grep { /\A[0-9]+\z/ } readdir $dh;
    closedir $dh;

    # Everyone holding it, not the first one found. A pre-forked server's
    # master and every one of its workers share the listening socket - all
    # six processes on the owner's own board held inode 35794984 - so the
    # first match is simply the lowest pid, which is the master only because
    # it happened to be created first. Once pids wrap past pid_max a worker
    # can be numbered below its own master, and a container's pid_max is far
    # smaller than a host's. Signalling a worker would reload that one worker
    # onto the new code and leave the rest on the old, with the once-per
    # -release mark written anyway: a board serving two versions at once,
    # silently and permanently. TKT-567.
    my @holding;
    for my $pid (@pids) {
        opendir my $fds, File::Spec->catdir( $proc, $pid, 'fd' ) or next;
        my @fd = grep { /\A[0-9]+\z/ } readdir $fds;
        closedir $fds;
        for my $fd (@fd) {
            my $target = readlink File::Spec->catfile( $proc, $pid, 'fd', $fd );
            next if !defined $target || $target !~ /\Asocket:\[(\d+)\]\z/;
            next if !$inode{$1};
            push @holding, 0 + $pid;
            last;
        }
    }
    return undef if !@holding;
    return $holding[0] if @holding == 1;

    # The master is the one nothing else in the set fathered: every worker's
    # parent is the master, and the master's parent is whatever launched the
    # board. Structural, so it holds whatever order the pids happen to fall
    # in. Exactly one such process, or none - two would mean this is not the
    # process tree we think it is, and refusing beats guessing when guessing
    # wrong means signalling a worker.
    my %in_set = map { $_ => 1 } @holding;
    my @rootmost = grep {
        my $ppid = Tira::CLI::_parent_of_pid( $_, proc => $proc );
        !defined $ppid || !$in_set{$ppid};
    } @holding;
    return @rootmost == 1 ? $rootmost[0] : undef;
}
# HUP, not a kill. Tira serves a .psgi FILE PATH rather than an in-memory
# coderef precisely so that Starman's HUP re-forks workers which read the
# modules from disk again - proved when that was chosen, and proved again
# here before this was built: a two-worker Starman on a .psgi reading a
# version from a file served "one", the file changed, the master got HUP,
# and it served "two" from fresh worker pids. Starman's own documentation
# says the same, and only --preload-app breaks it, which Tira does not use.
#
# The first design of this card stopped the master and launched a
# replacement. Michael asked the question that ended it: "After master
# process killed. The children still survived. Have you think of this side
# effect too?" - kill-and-relaunch has to get orphan reaping, port-free
# timing and a correct relaunch command all right, and HUP has none of those
# failure modes and drops no request, because workers finish what they are
# holding before they are replaced.
#
# Refusing is the default, and every refusal names itself: a board on
# slightly old code is a working board.
sub _dashboard_hup_if_stale {
    my ( $store, %opts ) = @_;
    my $port = $opts{port};
    return { hupped => 0, refused => 'no-port' } if !defined $port || $port !~ /\A[0-9]+\z/;

    my $on_disk = exists $opts{on_disk} ? $opts{on_disk} : Tira::CLI::_version_on_disk();
    return { hupped => 0, refused => 'unknown-version' } if !defined $on_disk;

    my $path = Tira::CLI::_dashboard_hup_mark_path($store);
    if ( open my $fh, '<', $path ) {
        my $done = do { local $/; <$fh> };
        close $fh;
        $done =~ s/\s+//g if defined $done;
        return { hupped => 0, refused => 'already-current' }
          if defined $done && length $done && $done eq $on_disk;
    }

    my $find = $opts{listening} || sub { _listening_pid( $_[0] ) };
    my $pid = $find->($port);
    return { hupped => 0, refused => 'no-board' } if !defined $pid;

    # Whoever holds the port is not necessarily the board, and SIGHUP's
    # default disposition is Term - so signalling a stranger that installs
    # no handler kills it outright. Proved rather than assumed: a plain
    # `perl -e 'sleep 300'` given HUP died with "Hangup". The board port is
    # a stable configured number, so any time the board is down and another
    # program has taken it, this would be a real process killed by a
    # supervisor that was only trying to reload a dashboard.
    #
    # What is checked is that it is a Starman, not that it is provably this
    # board. Two facts from the owner's own running board forced that:
    # Starman rewrites $0, so a live master's command line reads "starman
    # master" and names neither dashboard.psgi nor the command that started
    # it - an earlier version of this check looked for dashboard.psgi and
    # would have refused every genuine board while looking perfectly safe -
    # and assigning $0 on Linux clobbers the environ region too, so there is
    # no TIRA_DASHBOARD_ROOT left to read either. The parent is no help
    # (d2 tira.dashboard execs into Starman rather than forking, so the
    # master's parent is whatever shell launched it).
    #
    # A Starman is enough, because this guard exists to stop the one thing
    # that is actually destructive: signalling a process with no HUP handler,
    # which SIGHUP's default disposition then terminates. Every Starman
    # handles HUP, so the worst a misidentified one suffers is a graceful
    # reload of its own workers. The port comes from this board's own
    # project.yml, which is the real identifier - the owner's point exactly:
    # "Each application only hold their own port".
    #
    # An unreadable command line refuses like an unrecognised one, because
    # "cannot tell" is not "is safe to signal". TKT-566.
    my $identify = $opts{identify} || sub { Tira::CLI::_command_of_pid( $_[0] ) };
    my $command = $identify->($pid);
    return { hupped => 0, refused => 'not-a-board' }
      if !defined $command || $command !~ /\bstarman\b/i;

    my $signal = $opts{hup} || sub { kill 'HUP', $_[0] };
    $signal->($pid);

    File::Path::make_path($store) if !-d $store;
    if ( open my $fh, '>', $path ) {
        print {$fh} $on_disk;
        close $fh;
    }
    return { hupped => 1, pid => $pid, version => $on_disk };
}
sub _restart_if_updated {
    my ( $restarter, $command, $type, $project ) = @_;
    my $installed = Tira::installed_version();

    # Unreadable means unknown, and restarting on unknown would loop forever.
    return 0 if !defined $installed;

    # And so would restarting into the code already running. This used to
    # compare .env against the running version - two things a restart cannot
    # reconcile, because exec loads the same module again and disagrees with
    # .env again. His four boards did that every sixty seconds for twenty
    # hours, and the test suite did it once and hung for ever. The question is
    # not whether the label moved but whether the code did.
    my $on_disk = Tira::CLI::_version_on_disk();
    return 0 if !defined $on_disk || $on_disk eq $Tira::VERSION;

    # A restart that cannot work is worse than a stale board, because it turns
    # "running slightly old code" into "not running". So the target is checked
    # first, and if anything is missing the board simply carries on.
    my $script = Tira::CLI::_entrypoint_for( defined $type ? "$command.$type" : $command )
      // Tira::CLI::_entrypoint_for($command)
      or return 0;
    my @argv = grep { defined }
      map { /\A([^\x00-\x1f\x7f]*)\z/ ? $1 : undef } @Tira::CLI::RESTART_ARGV;
    return 0 if @argv != @Tira::CLI::RESTART_ARGV;

    # The board is handed over explicitly rather than left to be rediscovered,
    # so the new process does not depend on a working directory. It goes in the
    # environment because that is the only way to name a board now: there were
    # three - a flag, the environment and the working directory - and three
    # ways to say one thing is three behaviours to keep in agreement. It is set
    # rather than inherited, which is the same guarantee the flag gave.
    # TKT-250.
    return $restarter->( $script, @argv )
      if !defined $project || $project !~ /\S/;

    # Set for the new process rather than left to whatever it inherits, which
    # is the same guarantee the flag used to give. exec keeps the environment,
    # so naming it here is naming it there.
    local $ENV{TIRA_HOME} = $project;
    return $restarter->( $script, @argv );
}
# The viewer forces text-like content (html included) to plain text so
# nothing fetched from the store can execute inside the dialog's frame.
# CA18: per-call opt-in read-through cache. Entries live under the
# project's own .tira/cache (never a shared temp path), key on the full
# argument set, and are valid only while both the ttl holds and a board
# fingerprint (hi-res mtimes of the config, boards, columns, and
# attachment store) is unchanged — so any write invalidates immediately
# and a caller can never read its own stale data. A corrupt entry warns
# and falls back to a live read; a hit is always reported on stderr.
sub _board_fingerprint {
    my ($root) = @_;
    require Time::HiRes;
    my @stamps;
    my @paths = (
        File::Spec->catfile( $root, '.tira', 'project.yml' ),
        File::Spec->catdir( $root, '.tira', 'attachments' ),
    );

    # The counter Tira raises on every write. Modification times are the same
    # for two writes inside one clock tick on Windows - about sixteen
    # milliseconds - so a caller could be served the board as it was before its
    # own write. This has no clock in it.
    my $generation = File::Spec->catfile( $root, '.tira', '.generation' );
    if ( open my $fh, '<', $generation ) {
        my $line = <$fh>;
        close $fh;
        push @stamps, 'generation=' . ( defined $line ? $line : '' );
    }
    for my $type (qw(sow epic ticket)) {
        my $board = File::Spec->catdir( $root, '.tira', $type );
        push @paths, $board;
        my $dh;
        next if !opendir $dh, $board;
        my @entries = map { File::Spec->catdir( $board, $_ ) }
          sort grep { !/\A\./ } readdir $dh;
        closedir $dh;
        push @paths, @entries;

        # And the records themselves. A directory's modification time answers a
        # different question from the one being asked here: it changes when the
        # set of names changes, not when a file's contents do. A card edited in
        # place adds and removes no name, so on Windows the directory was
        # untouched, the cache was judged current, and the caller was served the
        # board as it was before its own write.
        for my $column ( grep { -d } @entries ) {
            my $files;
            next if !opendir $files, $column;
            push @paths, map { File::Spec->catfile( $column, $_ ) }
              sort grep { /\.json\z/ } readdir $files;
            closedir $files;
        }
    }
    for my $path (@paths) {
        my @stat = Time::HiRes::stat($path);
        push @stamps, $path . '=' . ( @stat ? $stat[9] : 'absent' );
    }
    return join ';', @stamps;
}
sub _restart_into {
    my (@argv) = @_;
    my ($perl) = $^X =~ /\A([^\x00-\x1f\x7f]+)\z/ or return 0;
    my $script = shift @argv or return 0;

    # Both the interpreter and the script are absolute here, so the search path
    # is never consulted to find them; taint mode objects to it regardless.
    # Handing the restarted process a known-safe path is better than laundering
    # whatever this one happened to inherit, and better than wiping it.
    # Both are absolute, so the search path is never consulted to find them;
    # this is about what the restarted process inherits. The POSIX directories
    # mean nothing on Windows, where emptying the path would break the child
    # rather than protect it, so only the shell variables go there.
    local $ENV{PATH} = '/usr/local/bin:/usr/bin:/bin' if !$Tira::CLI::WINDOWS;
    delete local @ENV{qw(IFS CDPATH ENV BASH_ENV)};

    exec( $perl, $script, @argv );
}
# Reading the table is kept apart from asking for it, so what this understands
# can be proved against real ps output on a machine where the answer is known.
sub _processes_from {
    my ($lines) = @_;
    my @processes;
    for my $line ( @{$lines} ) {

        # Day name, then two fields in whichever order this platform prints
        # them - Linux gives "Tue May 26" and macOS "Thu 13 Aug". Matching a
        # month name in a fixed position read 711 of 711 lines on Linux and 0
        # of 192 on macOS, so leftover-process reported nothing on a Mac
        # whatever was running.
        next if $line !~ /\A\s*(\d+)\s+(\w{3}\s+\w+\s+\w+\s+[\d:]+\s+\d{4})\s+(.*)\z/;
        my ( $pid, $started, $command ) = ( $1, $2, $3 );
        next if $pid == $$;
        push @processes,
          { pid => $pid, started_at => _stamp_from_ps($started), command => $command };
    }
    return \@processes;
}
# tasklist gives a quoted CSV of name, pid, session, session number and memory,
# and no start time at all. The time is left undefined rather than invented: a
# rule that asks how long something has been running can then tell that it does
# not know, where a made-up time would make every age wrong instead of absent.
sub _processes_from_windows {
    my ($lines) = @_;
    my @processes;
    for my $line ( @{$lines} ) {
        next if $line !~ /\A"([^"]*)","(\d+)"/;
        push @processes, { pid => 0 + $2, command => $1, started_at => undef };
    }
    return \@processes;
}
# Kept apart from asking Docker for the same reason: the suite runs inside a
# container with no Docker in it, so asking would prove nothing about whether
# the answer is understood. This is proved against real docker ps output.
sub _containers_from {
    my ($lines) = @_;
    my @containers;
    for my $line ( @{$lines} ) {
        my ( $name, $created ) = split /\t/, $line, 2;
        next if !defined $name || $name eq '';
        push @containers, { name => $name, started_at => _stamp_from_docker($created) };
    }
    return \@containers;
}
# What to ask for the process table. ps does not exist on Windows, and asking
# for it there is asking a question that can only be answered with nothing -
# and nothing is exactly what "no leftover processes" looks like.
#
# The platform is a parameter rather than read here, so both answers can be
# checked from anywhere. A Windows claim that can only be checked on Windows is
# one that goes unchecked, which is how this shipped eleven times.
sub _process_command {
    my ($windows) = @_;
    return $windows
      ? ( 'tasklist', '/fo', 'csv', '/nh' )
      : ( 'ps', '-eo', 'pid=,lstart=,args=' );
}
sub _stamp_from_docker {
    my ($text) = @_;
    return undef if !defined $text;
    return $text =~ /(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/
      ? "$1-$2-$3T$4:$5:$6"
      : undef;
}
# The month is whichever of the two fields is a month name, and the day is the
# other one. Deciding by platform would be wrong on the first machine whose
# locale prints something nobody anticipated; deciding by which field is a
# month needs no knowledge of where it is running at all.
sub _stamp_from_ps {
    my ($text) = @_;
    my %month = do { my $n = 0; map { $_ => ++$n } qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec) };
    return undef
      if $text !~ /\A\w{3}\s+(\w+)\s+(\w+)\s+(\d+):(\d+):(\d+)\s+(\d{4})\z/;

    my ( $first, $second, $hour, $minute, $second_of, $year ) = ( $1, $2, $3, $4, $5, $6 );
    my ( $name, $day ) =
        $month{$first}  ? ( $first,  $second )
      : $month{$second} ? ( $second, $first )
      :                   ( undef,   undef );
    return undef if !defined $name || $day !~ /\A\d+\z/;

    return sprintf '%04d-%02d-%02dT%02d:%02d:%02d',
      $year, $month{$name}, $day, $hour, $minute, $second_of;
}
1;

__END__

=head1 NAME

Tira::CLI::Serve - the machine a board is served on

=head1 DESCRIPTION

Which process is listening on a port, what is running on this machine, whether
the code under a live dashboard has moved, and how to hand over to a newer
version without dropping a request.

Loaded by C<Tira::CLI> with C<require> at the point one of those questions is
actually asked, so an ordinary card command never compiles any of it.

=head2 Where the process table readers belong

C<_processes_from>, C<_processes_from_windows>, C<_containers_from>,
C<_process_command>, C<_stamp_from_docker> and C<_stamp_from_ps> read the
machine. L<Tira::CLI::Police>'s world scan is their largest reader and calls
them here by name, which is the right way round: a helper belongs where its
subject is, not where its busiest caller is.

=head2 What stayed in Tira::CLI

C<_command_of_pid>, C<_parent_of_pid>, C<_entrypoint_for>, C<_version_on_disk>
and C<_dashboard_hup_mark_path> answer questions about this installation rather
than about the machine, so they stayed with the index and are called from here
by their full names.

=head1 SEE ALSO

L<Tira::CLI>, L<Tira::CLI::Police>

=cut
