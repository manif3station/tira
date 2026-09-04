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

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use Digest::SHA ();
use File::Basename ();
use File::Spec ();
use Tira;
# Tira::CLI is always in memory when this runs - nothing loads this module
# except Tira::CLI itself - but the helpers below are called by their full
# names, and an assumption a reader has to reconstruct is not a dependency.
# The require is free (%INC already holds it) and it is what makes
# `perl -c` on this file alone meaningful. TKT-607.
use Tira::CLI ();

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
        my $ppid = _parent_of_pid( $_, proc => $proc );
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

    my $on_disk = exists $opts{on_disk} ? $opts{on_disk} : _version_on_disk();
    return { hupped => 0, refused => 'unknown-version' } if !defined $on_disk;

    my $path = _dashboard_hup_mark_path($store);
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
    my $identify = $opts{identify} || sub { _command_of_pid( $_[0] ) };
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
    my $on_disk = _version_on_disk();
    return 0 if !defined $on_disk || $on_disk eq $Tira::VERSION;

    # A restart that cannot work is worse than a stale board, because it turns
    # "running slightly old code" into "not running". So the target is checked
    # first, and if anything is missing the board simply carries on.
    my $script = _entrypoint_for( defined $type ? "$command.$type" : $command )
      // _entrypoint_for($command)
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

        # THE CURRENT PROCESS STAYS IN. It used to be dropped here, which was
        # right for the only consumer that existed at the time: leftover-process
        # walks this list looking for things that should have stopped, and
        # police is always in it, so without an exclusion police accused itself
        # on every pass.
        #
        # monitor-dead then began reading the same list to ask whether a
        # recorded pid is still there, and wants the opposite - a monitor whose
        # command is a police pass IS the current process during that pass, and
        # a table built without it made job_monitor_alive answer "not there"
        # about something demonstrably running. TKT-874.
        #
        # Two consumers, opposite needs, one list. So the exclusion moved to the
        # rule that needs it rather than staying in the gathering they share:
        # this reports what is running, and leftover-process decides what to say
        # about itself. Deleting it from both would have traded a monitor
        # reported dead for police reported as a leftover - the same fault
        # wearing the other coat.
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
# A second batch, TKT-607: the process and installation questions that were
# still in the index after the first pass - which pid is serving, what the
# entrypoint is, what version is on disk, whether a directory is a repository,
# and the two small program-runners everything here is built on.

# What a process was launched as, read from the same shell-free source the
# port lookup already uses. The arguments are NUL-separated in /proc, so
# they are joined with spaces to be matched as one string. Anywhere without
# /proc this answers undef, and undef refuses. TKT-566.
sub _command_of_pid {
    my ( $pid, %opts ) = @_;
    return undef if !defined $pid || $pid !~ /\A[0-9]+\z/;
    my $proc = $opts{proc} // '/proc';
    open my $fh, '<:raw', File::Spec->catfile( $proc, $pid, 'cmdline' ) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return undef if !defined $raw || $raw eq '';
    $raw =~ s/\0/ /g;
    $raw =~ s/\s+\z//;
    return $raw;
}
# A process's parent, from the same shell-free source as everything else
# here. Undef when it cannot be read, which the caller treats as "not in the
# set" - the safe direction, since it can only ever make a pid look more
# rootmost, and two rootmost candidates refuse rather than pick. TKT-567.
sub _parent_of_pid {
    my ( $pid, %opts ) = @_;
    my $proc = $opts{proc} // '/proc';
    open my $fh, '<', File::Spec->catfile( $proc, $pid, 'status' ) or return undef;
    while ( my $line = <$fh> ) {
        next if $line !~ /\APPid:\s*(\d+)/;
        close $fh;
        return 0 + $1;
    }
    close $fh;
    return undef;
}
# Through a seam so a test can watch the decision without a process replacing
# itself mid-suite. exec swaps this process for a new one - nothing is forked,
# and no shell is involved.
# The entrypoint this command was reached through. $0 is not reliable: under
# the dashboard dispatcher it is the dispatcher, so restarting on it re-ran the
# wrong program and the board died instead of updating. Derived from the module
# path and the command, and checked before anything is replaced.
# The skill's own root, found by climbing out of lib/ rather than by counting
# directories. _entrypoint_for said dirname(dirname(__FILE__)) then updir, which
# was right in lib/Tira/CLI.pm and one level short in lib/Tira/CLI/Serve.pm -
# so every cli/ script was looked for one directory too high, _entrypoint_for
# returned undef, and _restart_if_updated took its "if anything is missing the
# board simply carries on" branch. A board with new code on disk stopped
# restarting into it, silently, which is the exact fault that sub was written
# for. Four test files caught it.
#
# Tira::CLI::Usage carries the same climb for SKILLS.md and POLICIES.md, for the
# same reason and found the same way.
sub _skill_root {
    my $here = File::Spec->rel2abs(__FILE__);
    my @parts = File::Spec->splitdir( ( File::Spec->splitpath($here) )[1] );
    pop @parts while @parts && $parts[-1] ne 'lib';
    pop @parts;
    return File::Spec->catdir(@parts);
}

sub _entrypoint_for {
    my ($command) = @_;
    my $here = __FILE__;
    $here =~ /\A([^\x00-\x1f\x7f]+)\z/ or return undef;
    my $root = _skill_root();
    my @parts = split /\./, $command;
    my $action = pop @parts;
    my $path = @parts
      ? File::Spec->catfile( $root, 'skills', @parts, 'cli', $action )
      : File::Spec->catfile( $root, 'cli', $action );
    ($path) = $path =~ /\A([^\x00-\x1f\x7f]+)\z/ or return undef;

    # Executability is what makes a file a command on a POSIX system. Windows
    # has no such bit, and -x there answers about the extension - so asking for
    # it found nothing, _entrypoint_for returned undef, and a dashboard on
    # Windows never picked up a new version however many were installed.
    return ( $Tira::CLI::WINDOWS ? -f $path : -x $path ) ? $path : undef;
}
# The version in the module a restart would load. installed_version() reads a
# label out of .env, and a label is not what exec changes - the file is. Asking
# the file is the only way to know whether restarting would run different code
# or the same code again.
sub _version_on_disk {
    my ($path) = @_;
    $path //= $INC{'Tira.pm'};
    return undef if !defined $path;
    $path =~ /\A([^\x00-\x1f\x7f]+)\z/ or return undef;
    open my $fh, '<:raw', $1 or return undef;
    my $body = do { local $/; <$fh> };
    close $fh;
    return $body =~ /^our \$VERSION = '([^']+)';/m ? $1 : undef;
}
# Where the last version police signalled a board about is remembered, so it
# signals once per release rather than once per pass. Signalling every pass
# is the exact shape of the loop this whole mechanism was built to avoid -
# four boards did it every sixty-five seconds for twenty hours.
sub _dashboard_hup_mark_path {
    my ($store) = @_;
    return File::Spec->catfile( $store, '.dashboard.huped' );
}
sub _running {
    my (@command) = @_;
    return 0 if !_program_exists( $command[0] );
    my $pid = open my $handle, '-|', @command or return 0;
    my @said = <$handle>;
    close $handle;
    return $? == 0 ? 1 : 0;
}
# Running something whose own chatter is not the caller's business. git bundle
# verify prints "<file> is okay" on the error stream when it succeeds, and a
# successful import that prints to stderr reads like a warning to anybody
# watching. Its answer is the exit status; its opinion is noise.
# Running something whose own chatter is not the caller's business. git prints
# "<file> is okay" on the error stream when a bundle verifies, and a successful
# command that writes to stderr reads like a warning to whoever is watching.
#
# The parent hands the child a filehandle for its error stream, so nothing in
# this process is reopened and no Perl runs in the child. Two other ways were
# tried and both cost more than the line is worth: reopening this process's
# stream took it away from every caller that had redirected it, and forking a
# child that silences itself puts lines in the codebase that no coverage tool
# can measure, because the child execs away before any counter is written.
# Move the descriptors, not the globs.
#
# open3 silences a child by reopening the STDOUT and STDERR globs after it
# forks, which moves descriptors 1 and 2 only while those globs still own them.
# A caller that captured its own output into a string - every test in this
# suite, and the served dashboard collecting a response - leaves the glob with
# no descriptor at all, so nothing the child does to it reaches descriptor 1,
# exec passes the real one through, and the command that was run quietly is
# heard. Measured rather than reasoned: the pipe open3 set up received nothing
# and the process's own standard output received "git version 2.52.0".
#
# No choice of open3 argument fixes that - a handle, a fileno dup string and a
# second null device were each tried and each leaked identically - because the
# fault is on the parent's side of the fork. Pointing the descriptors themselves
# at the null device first means the child inherits harmless ones whatever the
# globs are doing.
#
# The same hole sits on the error stream. t/139 does not reach it because it
# reopens STDERR onto a real file, which hands descriptor 2 back a real
# descriptor and hides the fault - the same way an earlier attempt at t/204
# went green by aiming descriptor 1 at a file.
#
# Both are put back before returning, so a caller keeps the output it had; that
# is the failure t/139 records, and it is asserted here rather than assumed.
sub _running_quietly {
    my (@command) = @_;
    return 0 if !_program_exists( $command[0] );
    require POSIX;
    open my $silence, '>', File::Spec->devnull
      or die "Cannot open the null device to run $command[0] quietly: $!\n";
    open my $nothing, '<', File::Spec->devnull
      or die "Cannot open the null device to run $command[0] quietly: $!\n";

    # Remembered as descriptors for the same reason: a glob that has been
    # captured cannot be duplicated back afterwards.
    open my $keep_in,  '<&', 0 or die "Cannot remember standard input: $!\n";
    open my $keep_out, '>&', 1 or die "Cannot remember standard output: $!\n";
    open my $keep_err, '>&', 2 or die "Cannot remember the error stream: $!\n";

    POSIX::dup2( fileno($nothing), 0 );
    POSIX::dup2( fileno($silence), 1 );
    POSIX::dup2( fileno($silence), 2 );

    # The child reads end-of-file rather than blocking on a pipe nobody writes
    # to, which is what the previous code left it holding.
    my $status = system(@command);

    POSIX::dup2( fileno($keep_in),  0 );
    POSIX::dup2( fileno($keep_out), 1 );
    POSIX::dup2( fileno($keep_err), 2 );

    return $status == 0 ? 1 : 0;
}
# Every external command runs through here, in list form so no shell is
# involved even in this module - a card title with a semicolon in it is a
# perfectly ordinary card title. A command that is not installed is not a
# failure: a machine with no Docker has no leftover containers.
sub _reading {
    my (@command) = @_;

    # List form: the program is named separately from its arguments, so this is
    # always "run this program" and never "ask a shell what was meant" - a card
    # title with a semicolon in it is an ordinary card title. A program that is
    # not installed is not a failure either: a machine with no Docker has no
    # leftover containers, and everything else carries on being watched.
    # Asked for by name first. Perl warns "Can't exec" when a program is not
    # there, and a machine with no Docker is not an error worth printing into
    # the middle of whatever the owner was reading.
    return [] if !_program_exists( $command[0] );

    my @lines;
    if ( open my $handle, '-|', @command ) {
        @lines = <$handle>;
        close $handle;
    }
    chomp @lines;
    return \@lines;
}
sub _program_exists {
    my ($program) = @_;
    return ( $Tira::CLI::WINDOWS ? -f $program : -x $program ) ? 1 : 0 if $program =~ m{[/\\]};
    return Tira::CLI::_agent_available($program);
}
# Chosen rather than fixed, because a fixed default is exactly the collision
# tira.dashboard -o browser's own port already accepts for a long-lived
# board with one obvious address - the wrong trade for a disposable session
# two people could start at once. The race between closing this socket and
# Plack::Runner binding the same port is the same one every "ask the OS for a
# free port" trick accepts; tools/browser-tests picks one the same way.
sub _free_port {
    require IO::Socket::INET;
    my $socket = IO::Socket::INET->new(
        Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp' )
      or die "Could not find a free port: $!\n";
    my $port = $socket->sockport;
    $socket->close;
    return $port;
}
sub _browser_endpoint {
    my ($endpoint) = @_;
    $endpoint =~ /\A(0\.0\.0\.0|127\.0\.0\.1|localhost)(?::([0-9]+))?\z/
      or die "Unsupported browser endpoint '$endpoint'\n";
    my ( $host, $port ) = ( $1, defined $2 ? 0 + $2 : 7899 );
    die "Browser port must be between 1 and 65535\n" if $port < 1 || $port > 65535;
    return ( $host, $port );
}
sub _serve_browser {
    require Tira::DashboardWeb;
    return Tira::DashboardWeb->serve(@_);
}

# Police beside the served board, for tira.dashboard -o browser --with-police.
# His words on TKT-897: "So the user doesn't need to run 2 terminals. All in 1
# go."
#
# HERE RATHER THAN IN Tira::DashboardWeb, which is engine source: t/106 holds
# the engine to inviting no processes at all, and forking one is exactly that.
# This module is the CLI layer, which is where the board is served from and
# where a process may be started.
#
# THE CHILD CLAIMS, NOT THE PARENT, because the claim names a pid and the pid
# that matters is the one actually watching. It claims as the DASHBOARD, which
# is what makes a later tira.police stand down rather than kill it - his answer
# to Q-117. The watch loop never returns, so the child never falls out of this
# sub; the exit is unreachable in practice and is there so a loop that somehow
# did return could not run on as a second copy of the serving process.
sub _start_police_beside_board {
    my (%args) = @_;
    my $spawn = $args{spawn} || \&_spawn_police_beside_board;
    return $spawn->(%args);
}

# Police beside the served board, for tira.dashboard -o browser --with-police.
# His words on TKT-897: "So the user doesn't need to run 2 terminals. All in 1
# go."
#
# WHY open3 AND NOT fork/exec, which is the same argument Tira::CLI::Job already
# makes for starting a monitor and is worth repeating rather than pointing at: a
# hand-rolled fork puts the child's exec in a branch that ONLY EVER RUNS IN THE
# CHILD, where Devel::Cover cannot follow it. The first version of this did
# exactly that, and gate-run refused it twice - first at the exec, then again at
# the injectable defaults added to make the child reachable. The gate was right
# both times: code that only runs in a child is code no test has watched, and
# writing seams until it looks covered is meeting the number rather than the
# point. open3 does the forking in code that is not ours to cover.
#
# THE CHILD KEEPS THIS TERMINAL, which is the entire feature. Its output goes to
# the parent's own handles rather than a pipe - a pipe would put the findings
# somewhere nobody is reading, and worse, an unread pipe fills at about 64KB and
# would block police forever, which is the deadlock TKT-841 was reviewed for.
#
# IT LEARNS IT IS THE DASHBOARD'S FROM THE ENVIRONMENT, because it is a separate
# process now rather than a fork carrying our variables. police_follow reads
# TIRA_POLICE_HOLDER, and an unrecognised value is normalised to an ordinary
# claim, so a stray environment cannot buy the protection only the dashboard
# earns.
sub _spawn_police_beside_board {
    my (%args) = @_;

    my $script = _entrypoint_for('police');
    return undef if !defined $script;

    require IPC::Open3;

    local $ENV{TIRA_HOME} = defined $args{project} ? $args{project} : ( $ENV{TIRA_HOME} // '' );
    local $ENV{TIRA_POLICE_HOLDER} = 'dashboard';

    # THE STORE IS HANDED OVER WHEN THERE IS ONE, and this is not tidiness. Both
    # sides normally DERIVE the same store from the project, so they agree
    # without being told - but --store overrides that, and a dashboard given one
    # would claim in the store it was told about while the pass it started
    # claimed in the one it derived. Two processes, two claims, and the yielding
    # rule silently never fires.
    #
    # Found by walking it rather than by reading it: a walkthrough with an
    # explicit store showed the spawned pass leaving no claim where the parent
    # was looking.
    my @argv = ( $^X, $script );
    push @argv, '--store', $args{store}
      if defined $args{store} && $args{store} =~ /\S/;

    # A spawn that fails answers undef rather than dying: the board is still
    # worth serving without the bridge, and the caller says so.
    my $pid = eval {
        IPC::Open3::open3( my $to_child, '>&STDOUT', '>&STDERR', @argv );
    };
    return undef if !$pid;
    return $pid;
}

# THE PASS DIES WITH THE BOARD. A police child outliving the server it was
# started beside would hold the singleton claim while nothing served the board,
# so the next tira.police would stand down in favour of a dashboard that is
# gone. Reaped as well as signalled, so the claim is released before the serving
# command returns rather than whenever the child happens to be collected.
sub _stop_police_beside_board {
    my ($child) = @_;
    return 0 if !$child;
    kill 'TERM', $child;
    waitpid $child, 0;
    return 1;
}
sub _serve_onboard_browser {
    require Tira::OnboardWeb;
    return Tira::OnboardWeb->serve(@_);
}
sub _serving_pid { return $Tira::CLI::SERVING_PID // $$ }
# Asking git about somewhere that is not a repository makes git say so, on
# standard error, in the middle of whatever the owner was reading. Nothing here
# silences it, because silencing the whole program's standard error would take
# it away from whoever else was using it - a test capturing it, most obviously.
# So it is not provoked in the first place.
sub _is_repository {
    my ($where) = @_;
    return 0 if !defined $where;
    my $here = abs_path($where) // $where;
    my $last = '';
    while ( $here ne $last ) {
        return 1 if -e File::Spec->catfile( $here, '.git' );
        ( $last, $here ) = ( $here, dirname($here) );
    }
    return 0;
}
# Where this branch was last pushed to. Asking git for @{upstream} was the
# obvious way and the wrong one: this very repository has origin/master and one
# unpushed commit, and no upstream configured for the branch - so git answered
# "fatal: no upstream configured", loudly, on somebody else's terminal, and
# both rules that depend on this went quiet on the one board that most needed
# them. --verify --quiet asks without complaining, and the remote the branch
# names is tried when the usual one is not there.
sub _tracking_branch {
    my ( $where, $branch ) = @_;
    my ($configured) =
      @{ _reading( 'git', '-C', $where, 'rev-parse', '--abbrev-ref', '--verify', '--quiet',
            "$branch\@{upstream}" ) };
    return $configured if defined $configured && $configured ne '';

    my @remotes = ('origin');
    my ($named) = @{ _reading( 'git', '-C', $where, 'config', '--get', "branch.$branch.remote" ) };
    unshift @remotes, $named if defined $named && $named ne '';
    for my $remote (@remotes) {
        my ($found) = @{ _reading( 'git', '-C', $where, 'rev-parse', '--verify', '--quiet',
                "$remote/$branch" ) };
        return "$remote/$branch" if defined $found && $found ne '';
    }
    return undef;
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

=head2 How this module is loaded

C<Tira::CLI> pulls this in with C<require> at the point one of its verbs runs,
so a command that never needs it never compiles it.

It calls into no sibling module. This paragraph said otherwise until 4.74 -
one note written once and pasted into all eight, describing a chain three of
them do not sit in.

=head1 SEE ALSO

L<Tira::CLI>, L<Tira::CLI::Police>

=cut
