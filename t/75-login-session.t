#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );

# The clock is driven by hand so the ten minutes can be walked past without
# the test taking ten minutes, and so "nine minutes then nine minutes again"
# is an exact statement rather than a race.
my $now = '2026-08-11T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
sub at { $now = $_[0]; return $now }

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Sessions', dir => $root,
    members => [ 'michael', 'ada', 'buildbot' ],
    columns => ['Backlog, Doing'],
    sow_prefix => 'SSS', epic_prefix => 'SSE', ticket_prefix => 'SST',
);
$tira->login_register( project => $root, id => 'michael', password => 'hunter2' );
$tira->login_register( project => $root, id => 'ada', password => 'correct horse' );

# --- opening a session ---------------------------------------------------

my $token = $tira->login_start( project => $root, id => 'michael', password => 'hunter2' );
ok( defined $token && length $token >= 32, 'a successful login answers with a long token' );

ok( !eval { $tira->login_start( project => $root, id => 'michael', password => 'wrong' ); 1 },
    'a wrong password opens nothing' );
ok( !eval { $tira->login_start( project => $root, id => 'buildbot', password => 'beep' ); 1 },
    'and a bot cannot open a session even by the front door' );

my $second = $tira->login_start( project => $root, id => 'ada', password => 'correct horse' );
isnt( $second, $token, 'two logins are two different sessions' );

# A token is a bearer credential: whoever holds it is the person. So it has to
# be unguessable, which means it must not be derived from the person, the
# clock, or anything else an outsider can work out.
my %tokens = ( $token => 1, $second => 1 );
for ( 1 .. 6 ) {
    $tokens{ $tira->login_start( project => $root, id => 'michael', password => 'hunter2' ) }++;
}
is( scalar keys %tokens, 8, 'every session gets its own token' );
# Independence, not a substring search. This asked that eight random hex tokens
# joined together contain none of "michael", "hunter2" or "2026" - and the year
# is four hex characters that occur by chance about once in every hundred and
# forty runs, which is what happened in the push gate on a release that touched
# nothing near it. It also proved nothing: a token that WAS the clock would pass
# whenever the year appeared in another form.
#
# The clock here is fixed, so a token derived from it would be identical across
# all eight - which the count above already catches - and a token derived from
# the person would be identical for the same person. What is left to check is
# the shape.
is( scalar( grep { /\A[0-9a-f]{32,}\z/ } keys %tokens ), 8,
    'every token is long random hex, giving away neither the person nor the moment' );

# Shown catching what it claims to catch. The shape assertion above would pass a
# token that was md5(person . moment) - thirty-two hex characters exactly - so
# the one that refuses a derived token is the count, and a count nobody has ever
# seen fail is a check that might not be watching anything.
{
    my $derived = sub {
        my ( $person, $moment ) = @_;
        my $sum = 0;
        $sum = ( $sum * 31 + ord ) % ( 2**31 ) for split //, "$person$moment";
        return sprintf '%032x', $sum;
    };
    my %derived = map { $derived->( 'michael', $now ) => 1 } 1 .. 8;
    is( scalar( grep { /\A[0-9a-f]{32,}\z/ } keys %derived ), 1,
        'a token derived from the person and the moment has the right shape' );
    isnt( scalar keys %derived, 8,
        'and eight logins produce one token rather than eight, which is what the count above refuses' );
}

# --- who is holding it ---------------------------------------------------

my $session = $tira->session_resume( project => $root, token => $token );
is( $session->{person}, 'michael', 'resuming a session says who it belongs to' );
is( $tira->session_resume( project => $root, token => $second )->{person}, 'ada',
    'and tells two people apart' );

is( $tira->session_resume( project => $root, token => 'not-a-real-token' ), undef,
    'an unknown token resumes nothing' );
is( $tira->session_resume( project => $root, token => '' ), undef,
    'and neither does an empty one' );

# --- ten minutes of doing nothing ----------------------------------------

# His answer: ten minutes counted from the last thing they did, not from when
# they logged in. So an afternoon of work is never interrupted and only an
# abandoned board locks itself.
at('2026-08-11T09:09:00Z');
ok( $tira->session_resume( project => $root, token => $token ),
    'nine minutes later the session is still good' );

at('2026-08-11T09:18:00Z');
ok( $tira->session_resume( project => $root, token => $token ),
    'and nine minutes after that too, because the clock restarted' );

at('2026-08-11T09:28:01Z');
is( $tira->session_resume( project => $root, token => $token ), undef,
    'but ten minutes of silence ends it' );
is( $tira->session_resume( project => $root, token => $token ), undef,
    'and it stays ended' );

# --- peeking, which is the whole of his fourth answer --------------------

# The board polls itself for updates. If that poll counted as activity, a tab
# left open overnight would keep its own session alive for ever and the ten
# minutes would mean nothing at all.
at('2026-08-11T10:00:00Z');
my $polled = $tira->login_start( project => $root, id => 'michael', password => 'hunter2' );
at('2026-08-11T10:05:00Z');
is( $tira->session_peek( project => $root, token => $polled )->{person}, 'michael',
    'peeking says who it is' );
at('2026-08-11T10:09:00Z');
ok( $tira->session_peek( project => $root, token => $polled ), 'and again a few minutes later' );
at('2026-08-11T10:10:01Z');
is( $tira->session_peek( project => $root, token => $polled ), undef,
    'but peeking never pushed the expiry out, so it still ends ten minutes after the login' );

# --- logging out ---------------------------------------------------------

my $ending = $tira->login_start( project => $root, id => 'ada', password => 'correct horse' );
ok( $tira->session_resume( project => $root, token => $ending ), 'a fresh session works' );
ok( $tira->session_end( project => $root, token => $ending ), 'and can be ended' );
is( $tira->session_resume( project => $root, token => $ending ), undef,
    'after which it is gone' );
ok( !eval { $tira->session_end( project => $root, token => 'never-existed' ); 1 },
    'ending a session that was never there is an error, not a quiet success' );

# --- surviving a restart -------------------------------------------------

# His second answer: an upgrade must not sign anyone out. The dashboard
# re-executes itself whenever Tira is installed, so a session held only in the
# running process would be lost every time I ship.
{
    my $fresh = Tira->new( clock => sub {$now} );
    my $survivor = $tira->login_start( project => $root, id => 'michael', password => 'hunter2' );
    is( $fresh->session_resume( project => $root, token => $survivor )->{person}, 'michael',
        'a session opened by one process is honoured by the next' );
}

# --- housekeeping --------------------------------------------------------

is_deeply(
    [ sort map { $_->{person} } @{ $tira->session_list( project => $root ) } ],
    [ 'michael' ],
    'listing shows only the sessions that are still alive' );

# Dead sessions must not pile up for ever in a directory nobody looks at.
my $sessions_dir = File::Spec->catdir( $root, '.tira', 'sessions' );
opendir my $dh, $sessions_dir or die "$sessions_dir: $!";
my @files = grep { !/\A\.\.?\z/ } readdir $dh;
closedir $dh;
is( scalar @files, 1, 'and the expired ones have been swept off the disk' );

# A session file is a bearer credential in a directory that may sit on a
# shared machine, so nobody else gets to read one.
my $mode = ( stat File::Spec->catfile( $sessions_dir, $files[0] ) )[2] & 07777;
SKIP: {
    skip 'file modes are not meaningful on this platform', 1 if $^O eq 'MSWin32';
    is( $mode & 077, 0, 'a session file is readable only by its owner' );
}

# Two people signing in within the same second must still list in a settled
# order, or the same board answers differently on two consecutive reads and
# anything built on that listing flickers.
{
    my @same_instant = (
        $tira->login_start( project => $root, id => 'michael', password => 'hunter2' ),
        $tira->login_start( project => $root, id => 'ada', password => 'correct horse' ),
    );
    my $listed = $tira->session_list( project => $root );
    is( scalar @{$listed}, 3, 'all three live sessions are listed' );
    is_deeply( [ map { $_->{token} } @{$listed} ],
        [ sort map { $_->{token} } @{$listed} ],
        'sessions that started in the same second fall back to a settled order' );
    is_deeply( $tira->session_list( project => $root ), $listed,
        'and the same order comes back on the next read' );
    $tira->session_end( project => $root, token => $_ ) for @same_instant;
}

# --- a token from another project ----------------------------------------

my $other = File::Spec->catdir( $tmp, 'other' );
$tira->project_new(
    name => 'Other', dir => $other, members => ['michael'],
    columns => ['Backlog, Doing'],
    sow_prefix => 'OTS', epic_prefix => 'OTE', ticket_prefix => 'OTT',
);
$tira->login_register( project => $other, id => 'michael', password => 'hunter2' );
my $elsewhere = $tira->login_start( project => $other, id => 'michael', password => 'hunter2' );
is( $tira->session_resume( project => $root, token => $elsewhere ), undef,
    'a session from one board is worth nothing on another' );

# --- a tampered token ----------------------------------------------------

# The token names the file it lives in, so anything that could climb out of
# that directory has to be refused rather than looked up.
# Planting a real session file exactly where a climbing token would land, so
# refusal is proved rather than assumed. Without the check on the token's shape
# these resolve to a file that exists and would be honoured - which is the
# difference between a guard and a comment.
{
    my $planted = Tira::json_object()->canonical->encode(
        { person => 'michael', started_at => $now, last_seen_at => $now } );
    for my $where ( [ '..', 'climbed.json' ], [ '..', '..', 'climbed.json' ] ) {
        my $path = File::Spec->catfile( $sessions_dir, @{$where} );
        open my $fh, '>:raw', $path or die "$path: $!";
        print {$fh} $planted;
        close $fh;
    }
}

for my $nasty ( '../climbed', '../../climbed', '..', 'a/b', "with\0null", 'UPPER-lower' ) {
    my $shown = $nasty =~ s/\0/\\0/gr;
    is( $tira->session_resume( project => $root, token => $nasty ), undef,
        "a token of '$shown' resumes nothing" );
    is( $tira->session_peek( project => $root, token => $nasty ), undef,
        "and peeking with '$shown' sees nothing either" );
}

done_testing;

__END__

=head1 NAME

75-login-session.t - TKT-002 sessions on disk, and the ten idle minutes

=head1 DESCRIPTION

The owner asked for a login that holds its session in a cookie for ten
minutes, and answered two questions that shape how it is built.

Sessions live on disk rather than in the running process, because the
dashboard re-executes itself whenever Tira is upgraded and an upgrade must
never sign anyone out. So this checks that a session opened by one engine is
honoured by the next.

The ten minutes is counted from the last thing a person did, not from when
they logged in. The board also polls itself for updates in the background, and
if that poll counted as activity a tab left open overnight would keep its own
session alive for ever - so peeking is a separate operation from resuming, and
peeking is proved here not to push the expiry out.

The rest is what a bearer credential needs: tokens that give away neither the
person nor the moment they were made, files no other user can read, expired
sessions swept rather than piling up, a token that is worthless on another
board, and refusal of anything that could climb out of the directory the
tokens name.

=cut
