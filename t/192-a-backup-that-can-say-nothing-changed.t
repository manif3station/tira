#!/usr/bin/env perl
# A backup of a board nobody touched says nothing changed.
#
# His observation, on the same morning as the board-unbacked report: "tira.backup
# reports changed: 1 on every single run, including runs seconds apart with
# nothing touched in between. It is possible each backup writes something (a
# stamp) that guarantees the next one has work to do."
#
# Nearly right, and the correction matters. Nothing the backup writes causes it.
# The store is <board>/.tira, and a session file under there is rewritten
# whenever anybody uses the board - reading it counts - so on a board being
# worked there is always something pending. Read off this project's own board:
#
#     $ git -C <board>/.tira status --porcelain
#      M .generation
#      M sessions/ee7eb879dee7cbbeb576b73f341ea8bac93156027349cef3.json
#      M ticket/backlog/TKT-129.json
#
# The consequence he noticed is the small one: "is this board already backed up"
# has no cheap answer, because changed: 0 is unreachable on a live board.
#
# The larger one is what a session is. It is the server side of somebody's
# sign-in, and it was being committed into the board's backup history for ever.
# The documentation already makes exactly this argument about the only other
# thing left out: "the lock file is the one thing left out, because a restored
# lock is somebody else's half-finished write". A restored session is somebody
# else's sign-in, which is worse - a stale lock stops one write, a restored
# session hands over an identity.
#
# Two things this deliberately does not do. It does not rewrite history: what a
# board has already committed stays committed, because a record somebody's
# tooling quietly rewrites is not evidence any more, and that principle is worth
# more than tidiness. And it does not stop at new boards - the ignore file was
# written only when the store was created, so a fix that touched only that path
# would leave every board that already exists tracking sessions for ever.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
# Tira::CLI::Serve holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Serve;

plan skip_all => 'git is not installed' if !Tira::CLI::Serve::_program_exists('git');

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'board' );

$tira->project_new(
    name => 'Quiet', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'QBS', epic_prefix => 'QBE', ticket_prefix => 'QBT',
);
$tira->create_record( project => $root, type => 'ticket', title => 'Something to back up' );

sub backup {
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'backup', tira => $tira,
            argv => [ '-o', 'json' ] ) };
    };
    die "backup failed (status $status): $err" if $status != 0;
    die "backup printed nothing (status $status, stderr: $err)" if !length $out;
    return Tira::json_decode($out);
}

sub tracked {
    my $store = File::Spec->catdir( $root, '.tira' );
    return [ @{ Tira::CLI::Serve::_reading( 'git', '-C', $store, 'ls-files' ) } ];
}

# --- the first backup has everything to say ------------------------------------------

my $first = backup();
is( $first->{changed}, 1, 'the first backup of a board has something to record' );

# --- a session appears, because somebody used the board --------------------------------
#
# Written by hand rather than by signing in, so the test is about what the
# backup does with the file rather than about how a session comes to exist.

{
    my $sessions = File::Spec->catdir( $root, '.tira', 'sessions' );
    mkdir $sessions;
    open my $fh, '>', File::Spec->catfile( $sessions, 'deadbeef.json' ) or die $!;
    print {$fh} qq({"person":"claude","expires_at":"2026-08-16T00:00:00Z"}\n);
    close $fh;
}

# --- and the backup does not take it -----------------------------------------------------

my $second = backup();
is_deeply( [ grep { m{\Asessions/} } @{ tracked() } ], [],
    'a session is not tracked in the backup: it is somebody else\'s sign-in' );

# --- so a board nobody has touched can say so ----------------------------------------------
#
# The answer to "is this board already backed up", which had none while something
# under the store changed on every read.

{
    my $again = backup();
    is( $again->{changed}, 0, 'backing up an untouched board reports nothing changed' );
}

# --- while a real change is still noticed -----------------------------------------------------
#
# The half that matters more: a backup that always says nothing changed is worse
# than one that always says something did.

{
    $tira->create_record( project => $root, type => 'ticket', title => 'A real change' );
    my $moved = backup();
    is( $moved->{changed}, 1, 'and a board that really changed still reports it' );
}

# --- a board whose store already tracks sessions stops tracking them -----------------------------
#
# The case that decides whether this reaches anybody. The ignore file was written
# only when the store was created, so a fix that touched only that path would
# leave every board that already exists exactly as it was.

{
    my $older = File::Spec->catdir( $tmp, 'older' );
    my $other = Tira->new;
    $other->project_new(
        name => 'Older', dir => $older, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'OLS', epic_prefix => 'OLE', ticket_prefix => 'OLT',
    );
    my $store = File::Spec->catdir( $older, '.tira' );

    # A store made the way they were made before this change: ignoring the lock
    # and nothing else.
    Tira::CLI::Serve::_running( 'git', '-C', $store, 'init', '--quiet' );
    open my $ignore, '>', File::Spec->catfile( $store, '.gitignore' ) or die $!;
    print {$ignore} ".lock\n";
    close $ignore;

    my $sessions = File::Spec->catdir( $store, 'sessions' );
    mkdir $sessions;
    open my $fh, '>', File::Spec->catfile( $sessions, 'cafebabe.json' ) or die $!;
    print {$fh} qq({"person":"claude"}\n);
    close $fh;

    Tira::CLI::Serve::_running( 'git', '-C', $store, 'add', '--all' );
    Tira::CLI::Serve::_running( 'git', '-C', $store, '-c', 'user.name=T', '-c', 'user.email=t@t',
        'commit', '--quiet', '-m', 'as boards were before' );

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $older; Tira::CLI->run( command => 'backup', tira => $other,
            argv => [ '-o', 'json' ] ) };
    }

    my $files = Tira::CLI::Serve::_reading( 'git', '-C', $store, 'ls-files' );
    is_deeply( [ grep { m{\Asessions/} } @{$files} ], [],
        'a board that already tracked sessions stops tracking them' );

    # And what it already committed is still there, because rewriting the
    # history of a backup would be worse than the thing it fixes.
    my $past = Tira::CLI::Serve::_reading( 'git', '-C', $store, 'log', '--all', '--name-only',
        '--format=', '--', 'sessions' );
    ok( scalar( grep { m{sessions/} } @{$past} ),
        'while the history it already wrote is left exactly as it was' );
}

done_testing;

__END__

=head1 NAME

192-a-backup-that-can-say-nothing-changed.t - sessions are not part of a backup

=head1 DESCRIPTION

A session file under the board's storage is rewritten whenever anybody uses the
board, so C<tira.backup> reported C<changed: 1> on every run and "is this board
already backed up" had no answer. Worse, the server side of somebody's sign-in
was being committed into the backup history.

Sessions are now left out, the way C<.lock> is and for the reason the
documentation already gives about it. Boards whose stores were made earlier stop
tracking them too, because the ignore file used to be written only at creation.
History already committed is left alone: rewriting the history of a backup is a
worse thing to own than the tidiness it would buy.

=cut
