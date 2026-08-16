#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;

# What the restart hands the new process, which is now an environment rather
# than an argument.
my $handover;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-09T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Restart', dir => $root, columns => ['Backlog, Doing'] );
$tira->create_record( project => $root, type => 'ticket', title => 'Something' );

# The version this process is running is not necessarily the one on disk: a
# dashboard left open for a week is serving whatever it started with.
is( Tira::installed_version(), $Tira::VERSION,
    'the installed version matches the running one in a clean checkout' );

# The data closure must be exercised while the mocked version is still in
# scope, or the test proves nothing about what the server would have seen.
sub serve {
    my (%args) = @_;
    my @restarted;
    my $captured;
    my $payload;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    my $status;
    {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        no warnings 'redefine';
        local *Tira::installed_version = sub { $args{installed} } if exists $args{installed};

        # Installing a new Tira replaces the module as well as the label in
        # .env, and it is the module that decides now - a label that moves on
        # its own is a restart into the same code, which is what looped his
        # boards for twenty hours. See t/123.
        local *Tira::CLI::_version_on_disk = sub { $args{installed} } if exists $args{installed};
        local $ENV{TIRA_HOME} = $root;
        $status = do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
            command => 'dashboard', type => 'ticket',
            argv => [ '-o', 'browser' ],
            tira => $tira,
            browser_server => sub { my %given = @_; $captured = \%given; return 1 },
            restarter => sub { $handover = $ENV{TIRA_HOME}; push @restarted, [@_]; return 1 },
        ) };
        $payload = $captured->{data}->() if $captured;
    }
    return ( $status, $captured, \@restarted, $payload );
}

# Nothing has changed, so nothing restarts.
{
    my ( $status, $served, $restarted, $body ) = serve();
    is( $status, 0, 'the board serves' );
    my $payload = decode_json($body);
    is( $payload->{_version}, $Tira::VERSION,
        'the data says which version is actually serving it' );
    is_deeply( $restarted, [], 'and an unchanged version restarts nothing' );
}

# Somebody installs a new Tira under a running dashboard.
{
    my ( $status, $served, $restarted ) = serve( installed => '9.99' );
    is( scalar @{$restarted}, 1, 'a new version on disk restarts the server' );
    my ( $script, @argv ) = @{ $restarted->[0] };

    # $0 is the dispatcher when the board is launched through it, so restarting
    # on $0 re-ran the wrong program and the board died instead of updating.
    # The entrypoint is derived from the command rather than assumed.
    # A board opened as tira.dashboard.ticket must come back as that board,
    # not as the combined one, so the entrypoint follows the type too.
    # Separators are the platform's own: File::Spec builds them, so the
    # assertion asks for the path it would build rather than a POSIX-shaped one.
    my $wanted = File::Spec->catfile( qw(skills dashboard cli ticket) );
    like( $script, qr{\Q$wanted\E\z},
        'it restarts the entrypoint for the exact command that was running' );
    ok( ( $^O eq 'MSWin32' ? -f $script : -x $script ), 'which really exists and can be run' );
    # The whole list, not a slice of it. This took the first four because the
    # flag and its value filled two of them, and a slice that expects padding
    # goes on passing when the padding becomes undef. TKT-250.
    is_deeply( \@argv, [ '-o', 'browser' ],
        'with the arguments it was started with, and nothing else' );

    # Named in the environment rather than on the command line, because the
    # command line no longer has a place for it - there is one way to say which
    # board and this is it. Still set rather than inherited, which is the same
    # guarantee the flag gave: the new process may not have the working
    # directory that found it first. TKT-250.
    is( scalar( grep { $_ eq '--project' } @argv ), 0,
        'and no flag naming the board, because there is no such flag' );
    is( $handover, $root,
        'the board named to the new process in the environment' );
}

# A board launched without --project must still come back pointing at the same
# project: this is what failed in the field, where the restart lost it and died
# with an empty selector.
{
    my @restarted;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        local $ENV{TIRA_HOME} = $root;
        no warnings 'redefine';
        local *Tira::installed_version = sub { '9.99' };
        local *Tira::CLI::_version_on_disk = sub { '9.99' };
        my $captured;
        Tira::CLI->run(
            command => 'dashboard', type => 'ticket',
            argv => [ '-o', 'browser' ], tira => $tira,
            browser_server => sub { my %given = @_; $captured = \%given; return 1 },
            restarter => sub { $handover = $ENV{TIRA_HOME}; push @restarted, [@_]; return 1 },
        );
        $captured->{data}->() if $captured;
    }
    is( scalar @restarted, 1, 'a board restarts' );
    my ( $script, @argv ) = @{ $restarted[0] };
    is( scalar( grep { $_ eq '--project' } @argv ), 0,
        'with nothing on the command line naming the board' );
    is( $handover, $root,
        'and is told which board in the environment, rather than left to rediscover it' );
}

# A restart that cannot work is worse than a stale board: it turns running old
# code into not running at all.
{
    no warnings 'redefine';
    local *Tira::CLI::_entrypoint_for = sub { undef };
    my ( $status, $served, $restarted ) = serve( installed => '9.99' );
    is_deeply( $restarted, [],
        'with no entrypoint to restart into, the board carries on rather than dying' );
}

# An unreadable .env must not put the server in a restart loop.
{
    my ( $status, $served, $restarted ) = serve( installed => undef );
    is_deeply( $restarted, [], 'an unknown version is treated as no change, not as an update' );
}

# The page carries the version it was built by, so it can tell when the server
# has moved on. It reloads only then - reloading while the old process still
# serves would just fetch the same page again.
my $html = $tira->format_output(
    $tira->dashboard( project => $root, type => 'ticket', summary => 1 ),
    output => 'table', project => $root, live => 1 );
like( $html, qr/data-version="\Q$Tira::VERSION\E"/, 'the page records the version that built it' );
like( $html, qr/data\._version&&data\._version!==document\.documentElement\.dataset\.version/,
    'and compares it with the one actually serving' );
like( $html, qr/location\.reload\(\);return\}/, 'reloading when they differ' );

# The static board has no server to ask, so it must not carry the check.
my $static = $tira->format_output(
    $tira->dashboard( project => $root, type => 'ticket', summary => 1 ),
    output => 'table', project => $root );
# non-empty is the whole claim: a precondition for the denial that follows.
like( $static, qr/\S/, 'the static board rendered, so the denial below is about a page' );
unlike( $static, qr/data\._version/,
    'a static board does not poll for a version it can never be told about' );

# The restart itself. exec replaces this process, so it is exercised in a child
# that is allowed to be replaced - proving it really does re-run the command
# rather than merely being called.
{
    my $script = File::Spec->catfile( $tmp, 'restarted.pl' );
    open my $fh, '>', $script or die $!;
    # Escaped, or the outer string interpolates this test's own (empty) \@ARGV
    # when the file is written, and the child would prove nothing.
    print {$fh} 'print qq{restarted with: @ARGV\n}; exit 0;' . "\n";
    close $fh;

    my $marker = File::Spec->catfile( $tmp, 'proof.txt' );
    my $pid = fork();
    die "cannot fork: $!" if !defined $pid;
    if ( !$pid ) {
        open my $out, '>', $marker or exit 1;
        open STDOUT, '>&', $out or exit 1;
        Tira::CLI::_restart_into( $script, 'one', 'two' );
        exit 99;    # only reached if exec failed to replace us
    }
    waitpid $pid, 0;
    my $exit = $? >> 8;
    is( $exit, 0, 'the restart replaced the process rather than returning' );
    open my $in, '<', $marker or die $!;
    my $said = do { local $/; <$in> };
    close $in;
    like( $said, qr/restarted with: one two/,
        'and re-ran the command with the arguments it was given' );
}

# Nothing to restart into is a refusal rather than a broken exec.
is( Tira::CLI::_restart_into(), 0, 'with no script named, nothing is replaced' );

# And the entrypoint really is found for a plain command as well as a typed one.
my $bare = File::Spec->catfile( qw(cli dashboard) );
like( Tira::CLI::_entrypoint_for('dashboard'), qr{\Q$bare\E\z},
    'a command with no type resolves to its own entrypoint' );
is( Tira::CLI::_entrypoint_for('no.such.command'), undef,
    'and a command that ships no entrypoint resolves to nothing, rather than a guess' );

# --- where there is no execute bit ----------------------------------------

# The entrypoint to restart into is found by asking whether a file is
# executable. Windows has no such bit and -x there answers about the extension,
# so nothing was ever found, and a dashboard running on Windows never picked up
# a new version however many were installed. Driven here rather than left to a
# lab that is visited once a release.
{
    # The entrypoint the board would restart into, with its execute bit taken
    # off for the length of this block: that is the whole of what Windows looks
    # like to this code, and it cannot be imitated by setting a flag alone.
    # Both candidates, because the lookup falls back from the type-specific
    # entrypoint to the general one, and leaving either executable would let
    # the restart happen for the wrong reason.
    my @entrypoints = grep { -e } (
        File::Spec->catfile( 'skills', 'dashboard', 'cli', 'ticket' ),
        File::Spec->catfile( 'cli', 'dashboard' ),
    );
    ok( scalar @entrypoints, 'the entrypoints a restart would use are there to begin with' );
    my %mode = map { $_ => ( ( stat $_ )[2] & 07777 ) } @entrypoints;

    chmod $mode{$_} & ~0111, $_ for @entrypoints;
    my $restored = 0;
    my $guard = Guard::On::Scope->new(
        sub { chmod $mode{$_}, $_ for @entrypoints; $restored = 1 } );

    {
        local $Tira::CLI::WINDOWS = 0;
        my ( undef, undef, $restarted ) = serve( installed => '9.99' );
        is_deeply( $restarted, [],
            'a file with no execute bit is not something to restart into on a POSIX system' );
    }
    {
        local $Tira::CLI::WINDOWS = 1;
        my ( undef, undef, $restarted ) = serve( installed => '9.99' );
        is( scalar @{$restarted}, 1,
            'and on Windows, where there is no such bit, it is - which is why a board there never updated itself' );
    }

    undef $guard;
    ok( $restored, 'and the files are left exactly as they were found' );
    is_deeply( [ map { ( stat $_ )[2] & 07777 } @entrypoints ],
        [ map { $mode{$_} } @entrypoints ], 'with their own modes back' );
}

{
    package Guard::On::Scope;
    sub new { my ( $class, $code ) = @_; return bless { code => $code }, $class }
    sub DESTROY { $_[0]{code}->() }
}

done_testing;

__END__

=head1 NAME

66-self-restart.t - a dashboard that picks up a new Tira by itself

=head1 DESCRIPTION

A dashboard left open is serving whatever Tira it started with, so
updating meant visiting every open board and restarting it by hand.
Proves the server notices a new version on disk and re-executes itself
with the arguments it was started with, that an unchanged or unreadable
version does not, and that the page reloads only once the version
actually being served differs from the one that built it - reloading
any earlier would just fetch the same old page from the same old
process.

=cut
