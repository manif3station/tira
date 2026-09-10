#!/usr/bin/env perl
# tools/gate-run line 52 makes a worktree, line 60 checks it out, and until
# TKT-901 an EXIT trap removed that worktree without ever telling the docker
# container mounted on it to stop. Killing gate-run mid-run let the trap fire
# (bash runs its EXIT trap on a received signal even though the run itself
# does not complete), which deleted the worktree out from under a container
# still running against it - measured on TKT-893, 2026-09-03: a container ran
# 21:57 to 22:47 after its host process had already been killed at 22:46, and
# the coverage step then failed with "no modules found under lib/" because
# lib/ had been deleted mid-run rather than because coverage was actually
# short.
#
# This test kills gate-run mid-run against a mocked "docker" that stands in
# for a running container, and checks the fix's own two obligations: the
# container is told to stop, and it is told to stop BEFORE the worktree it
# was mounted on is removed - not merely stopped eventually.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Run qw(run_quietly);

my $root = File::Spec->rel2abs('.');

plan skip_all => 'git is not installed here' if system('git --version >/dev/null 2>&1') != 0;

my $tmp   = tempdir( CLEANUP => 1 );
my $repo  = File::Spec->catdir( $tmp, 'skills', 'faketira' );
my $tools = File::Spec->catdir( $repo, 'tools' );
mkdir File::Spec->catdir( $tmp, 'skills' ) or die $!;
mkdir $repo  or die $!;
mkdir $tools or die $!;

my $fake_lib = File::Spec->catdir( $repo, 'lib', 'Tira' );
require File::Path;
File::Path::make_path($fake_lib) or die $! if !-d $fake_lib;
for my $module (qw(lib/Tira.pm lib/Tira/CLI.pm)) {
    open my $fh, '>', File::Spec->catfile( $repo, split m{/}, $module ) or die $!;
    print {$fh} "1;\n";
    close $fh;
}

open my $compose, '>', File::Spec->catfile( $tmp, 'docker-compose.testing.yml' ) or die $!;
print {$compose} "services: {}\n";
close $compose;

my $gate_run_source = do {
    open my $in, '<', File::Spec->catfile( $root, 'tools', 'gate-run' ) or die $!;
    local $/;
    <$in>;
};
open my $out, '>', File::Spec->catfile( $tools, 'gate-run' ) or die $!;
print {$out} $gate_run_source;
close $out;
chmod 0755, File::Spec->catfile( $tools, 'gate-run' ) or die $!;

is( run_quietly( 'git', 'init', '-q', $repo ), 0, 'a throwaway repository to run the mocked gate against' );
for my $setting ( [ 'user.email', 'nobody@example.invalid' ], [ 'user.name', 'Nobody' ] ) {
    run_quietly( 'git', '-C', $repo, 'config', @{$setting} );
}
open my $tracked, '>', File::Spec->catfile( $repo, 'tracked-file' ) or die $!;
print {$tracked} "version one\n";
close $tracked;
run_quietly( 'git', '-C', $repo, 'add', '-A' );
run_quietly( 'git', '-C', $repo, 'commit', '-q', '-m', 'first commit' );

# --- a mocked "docker" standing in for a container that outlives a kill ----
#
# "run" blocks the way a real container does while the suite runs inside it -
# long enough for the test to kill gate-run while it is still up. "rm"/"kill"
# is the shape gate-run's own cleanup is expected to call to stop it; the mock
# records, at the moment it is invoked, whether the worktree it was mounted on
# still exists - the one fact that tells the two failure modes apart, since a
# stop call made after the worktree is already gone proves nothing.

my $bin        = File::Spec->catdir( $tmp, 'bin' );
my $state      = File::Spec->catdir( $tmp, 'state' );
mkdir $bin   or die $!;
mkdir $state or die $!;
my $events_log    = File::Spec->catfile( $state, 'events' );
my $container_pid = File::Spec->catfile( $state, 'container.pid' );

# Every substitution the two mocks below need (the state directory, the real
# git binary) travels as an environment variable rather than being baked into
# the script text - a single-quoted heredoc stays entirely literal, so bash's
# own $1/$@/$$ need no escaping and cannot be mistaken for Perl interpolation.
my $real_git = do {
    my ($found) = grep { -x File::Spec->catfile( $_, 'git' ) } split /:/, $ENV{PATH};
    die "no real git found on PATH" if !$found;
    File::Spec->catfile( $found, 'git' );
};

local $ENV{PATH}          = "$bin:$ENV{PATH}";
local $ENV{FAKE_GATE_STATE} = $state;
local $ENV{FAKE_REAL_GIT}   = $real_git;

my $docker = File::Spec->catfile( $bin, 'docker' );
open my $docker_fh, '>', $docker or die $!;
print {$docker_fh} <<'FAKE_DOCKER';
#!/usr/bin/env bash
STATE="$FAKE_GATE_STATE"
case "$*" in
  *" run "*)
    # child pid recorded and the TERM trap armed BEFORE announcing
    # "container-started" - the test waits for that marker before sending
    # its kill, and a kill landing before the trap exists would be a flake
    # in the test's own timing, not a fact about gate-run under test.
    echo $$ > "$STATE/container.pid"
    sleep 30 &
    sleep_pid=$!
    echo "$sleep_pid" > "$STATE/container.child.pid"
    trap 'kill "$sleep_pid" 2>/dev/null; wait "$sleep_pid" 2>/dev/null; exit 143' TERM
    echo "container-started" >> "$STATE/events"
    wait "$sleep_pid"
    ;;
  "rm "*|"kill "*)
    TREE=$(cat "$STATE/tree-path" 2>/dev/null)
    if [ -n "$TREE" ] && [ -d "$TREE" ]; then
      echo "stop-called worktree-present" >> "$STATE/events"
    else
      echo "stop-called worktree-absent" >> "$STATE/events"
    fi
    if [ -f "$STATE/container.pid" ]; then
      kill -TERM "$(cat "$STATE/container.pid")" 2>/dev/null || true
    fi
    ;;
  *)
    exit 0
    ;;
esac
FAKE_DOCKER
close $docker_fh;
chmod 0755, $docker or die $!;

# gate-run's own tree var is a mktemp'd directory it creates itself; to let
# the mock know when that directory has been removed, gate-run's own worktree
# add target is recorded into state/tree-path by wrapping git - the simplest
# observation point, since that mktemp'd directory is exactly what "git
# worktree remove" deletes, so its continued existence IS the fact under test.
my $git_wrapper = File::Spec->catfile( $bin, 'git' );
open my $git_fh, '>', $git_wrapper or die $!;
print {$git_fh} <<'GIT_WRAPPER';
#!/usr/bin/env bash
if [ "$1" = "worktree" ] && [ "$2" = "add" ]; then
  # the worktree path is the argument right before HEAD's ref
  echo "${@: -2:1}" > "$FAKE_GATE_STATE/tree-path"
fi
exec "$FAKE_REAL_GIT" "$@"
GIT_WRAPPER
close $git_fh;
chmod 0755, $git_wrapper or die $!;

# --- kill gate-run once its mocked container is up --------------------------

my $pid = fork();
die "fork: $!" if !defined $pid;
if ( $pid == 0 ) {
    chdir $repo or die $!;
    close STDOUT;
    close STDERR;
    exec( File::Spec->catfile( $tools, 'gate-run' ) );
    die "exec: $!";
}

my $waited = 0;
while ( $waited < 10 && !-e $events_log ) {
    select( undef, undef, undef, 0.2 );
    $waited += 0.2;
}
ok( -e $events_log, 'the mocked container came up before the kill' )
  or diag('the mocked container never started - gate-run may have exited before reaching docker');

kill( 'TERM', $pid );

my $reaped = 0;
$waited = 0;
while ( $waited < 10 ) {
    my $r = waitpid( $pid, 1 );    # WNOHANG
    if ( $r == $pid ) { $reaped = 1; last }
    select( undef, undef, undef, 0.2 );
    $waited += 0.2;
}
ok( $reaped, 'gate-run itself exited after being killed' );

# give the trap's own docker rm/kill call, and the container's own reaction to
# it, a moment to land in the events log.
$waited = 0;
while ( $waited < 5 && !-e $container_pid ) {
    select( undef, undef, undef, 0.2 );
    $waited += 0.2;
}
my $container_still_alive = 1;
if ( -e $container_pid ) {
    open my $fh, '<', $container_pid or die $!;
    chomp( my $cpid = <$fh> );
    close $fh;
    $waited = 0;
    while ( $waited < 5 ) {
        $container_still_alive = kill( 0, $cpid ) ? 1 : 0;
        last if !$container_still_alive;
        select( undef, undef, undef, 0.2 );
        $waited += 0.2;
    }
}

# The mock shell dying is not enough on its own - its own "sleep 30" child,
# the thing actually standing in for the running container's work, has to be
# reaped too, or it lingers up to 30 seconds after its parent is already gone.
my $child_pid_file = File::Spec->catfile( $state, 'container.child.pid' );
my $child_still_alive = 1;
if ( -e $child_pid_file ) {
    open my $fh, '<', $child_pid_file or die $!;
    chomp( my $child_pid = <$fh> );
    close $fh;
    $waited = 0;
    while ( $waited < 5 ) {
        $child_still_alive = kill( 0, $child_pid ) ? 1 : 0;
        last if !$child_still_alive;
        select( undef, undef, undef, 0.2 );
        $waited += 0.2;
    }
}
ok( !$container_still_alive,
    'the container gate-run started does not survive being killed - nothing is left running for docker ps to find' );
ok( !$child_still_alive,
    'nor does the work it was running (the sleep standing in for the suite) - a dead shell with a live child is still a leak' );

my $events = '';
if ( open my $fh, '<', $events_log ) {
    local $/;
    $events = <$fh>;
    close $fh;
}
like( $events, qr/\bstop-called\b/,
    'gate-run told the container to stop rather than only removing the worktree' );
like( $events, qr/stop-called worktree-present/,
    'and it did so while the worktree it was mounted on still existed - a stop after the fact proves nothing' );
unlike( $events, qr/stop-called worktree-absent/,
    'no stop call ever landed after the worktree had already been removed' );

done_testing();

__END__

=head1 NAME

t/901-a-run-killed-mid-suite-orphans-nothing.t - a killed gate-run stops its own container before removing the worktree

=head1 WHY

TKT-901: C<tools/gate-run>'s EXIT trap removed the worktree it had checked
out but never told the docker container mounted on it to stop - measured on
TKT-893, 2026-09-03: a container ran 21:57 to 22:47 after its host process
had already been killed at 22:46, and the coverage step then failed with "no
modules found under lib/" because C<lib/> had been deleted mid-run, not
because coverage was actually short.

=head1 WHAT IS ASSERTED

A mocked "docker" stands in for the container and a thin "git" wrapper
records the worktree gate-run creates. A real C<gate-run> is started, killed
once its mocked container is up, and the test checks that the container
itself dies (nothing left for C<docker ps> to find) and that the mocked
stop call landed while the worktree still existed - proving the ordering, not
merely that a stop eventually happened.

=cut
