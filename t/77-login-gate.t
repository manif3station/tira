#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Request::Common qw(GET POST);
use Cpanel::JSON::XS qw(decode_json);
use Encode ();
use Plack::Test;
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'gated' );
my $now = '2026-08-11T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
$tira->project_new(
    name => 'Gated', dir => $root, members => [ 'michael', 'buildbot' ],
    columns => ['Backlog, Doing'],
    sow_prefix => 'GTS', epic_prefix => 'GTE', ticket_prefix => 'GTT',
);
$tira->login_register( project => $root, id => 'michael', password => 'hunter2' );

my %called;
my $app = Tira::DashboardWeb->build_psgi_app(
    Tira::CLI::browser_providers( tira => $tira, project => $root ),
    render => sub { $called{render}++; return '<!doctype html><p>BOARD-SENTINEL</p>' },
    data => sub { $called{data}++; return '{"ticket":{"backlog":[]}}' },
);

# Every route the board exposes, and what a stranger must get from each. The
# list is spelled out rather than derived, so a route added later without a
# thought for the gate shows up here as a hole rather than passing silently.
my @reads = qw(/ /data /record /people /columns /search /link-types /attachment);
my @writes = qw(
  /move /create /update /columns/apply
  /question/answer /question/mark /question/attach
  /comment/add /comment/update /comment/remove
  /attachment/add /attachment/remove
  /checklist/add /checklist/update
  /hierarchy/link /hierarchy/unlink /subitem/link /subitem/unlink
  /link/add /link/remove
);

test_psgi $app, sub {
    my ($http) = @_;

    # --- a stranger ------------------------------------------------------

    # His answer: everyone lands on the login page until they are in. So the
    # front door shows the login rather than the board, and every other route
    # refuses outright - a login page rendered into a card would be worse than
    # an error.
    my $front = $http->( GET '/' );
    is( $front->code, 200, 'the front door answers a stranger' );
    like( $front->content, qr/type="password"/, 'with a login page' );
    unlike( $front->content, qr/BOARD-SENTINEL/, 'and not with the board behind it' );
    ok( !$called{render}, 'the board was never even rendered for them' );

    for my $path ( grep { $_ ne '/' } @reads ) {
        my $response = $http->( GET $path );
        is( $response->code, 401, "GET $path refuses a stranger" );
        like( $response->header('Content-Type'), qr{application/json},
            "and answers JSON so the board's own scripts can react" );
    }
    ok( !$called{data}, 'no data provider ran for any of them' );

    for my $path (@writes) {
        my $response = $http->( POST $path, Content => '{}' );
        is( $response->code, 401, "POST $path refuses a stranger" );
    }

    # --- signing in ------------------------------------------------------

    my $wrong = $http->( POST '/login', Content => '{"id":"michael","password":"nope"}' );
    is( $wrong->code, 401, 'a wrong password does not get in' );
    ok( !$wrong->header('Set-Cookie'), 'and is handed no cookie' );

    my $bot = $http->( POST '/login', Content => '{"id":"buildbot","password":"beep"}' );
    is( $bot->code, 401, 'nor does a bot' );

    my $login = $http->( POST '/login', Content => '{"id":"michael","password":"hunter2"}' );
    is( $login->code, 200, 'the right password gets in' );
    my $cookie = $login->header('Set-Cookie') // '';
    like( $cookie, qr/tira_session=/, 'and is handed a session cookie' );

    # A cookie holding a bearer credential must be out of reach of any script
    # on the page and must not ride along on requests from other sites.
    like( $cookie, qr/HttpOnly/i, 'the cookie is out of reach of scripts' );
    like( $cookie, qr/SameSite=(?:Lax|Strict)/i, 'and does not ride along from other sites' );
    like( $cookie, qr{Path=/}, 'and covers the whole board' );

    my ($token) = $cookie =~ /tira_session=([^;]+)/;

    # --- signed in -------------------------------------------------------

    my $board = $http->( GET '/', Cookie => "tira_session=$token" );
    is( $board->code, 200, 'now the front door answers' );
    like( $board->content, qr/BOARD-SENTINEL/, 'with the board' );
    unlike( $board->content, qr/type="password"/, 'and no login page' );

    # Some of these need parameters and answer an error without them. What
    # matters here is only whether the gate let them past.
    for my $path ( grep { $_ ne '/' && $_ ne '/attachment' } @reads ) {
        isnt( $http->( GET $path, Cookie => "tira_session=$token" )->code, 401,
            "GET $path is no longer refused once signed in" );
    }
    isnt( $http->( POST '/move', Content => '{}', Cookie => "tira_session=$token" )->code,
        401, 'and a mutation is allowed past the gate' );

    # --- a cookie that was made up ---------------------------------------

    for my $bad ( 'deadbeef', '../project.yml', '', 'x' x 200 ) {
        is( $http->( GET '/data', Cookie => "tira_session=$bad" )->code, 401,
            "a made-up cookie of '" . substr( $bad, 0, 12 ) . "' is refused rather than trusted" );
    }

    # --- the poll must not keep the session alive ------------------------

    # His fourth answer, at the seam where it actually matters: the board polls
    # /data on a timer whether anyone is there or not.
    $now = '2026-08-11T09:09:00Z';
    is( $http->( GET '/data', Cookie => "tira_session=$token" )->code, 200,
        'the poll works while the session is alive' );
    $now = '2026-08-11T09:10:01Z';
    is( $http->( GET '/data', Cookie => "tira_session=$token" )->code, 401,
        'but polling never extended it, so it ends ten minutes after the last real action' );

    # --- a real action does keep it alive --------------------------------

    $now = '2026-08-11T10:00:00Z';
    my $again = $http->( POST '/login', Content => '{"id":"michael","password":"hunter2"}' );
    my ($live) = ( $again->header('Set-Cookie') // '' ) =~ /tira_session=([^;]+)/;

    $now = '2026-08-11T10:09:00Z';
    is( $http->( GET '/people', Cookie => "tira_session=$live" )->code, 200,
        'a real action nine minutes in works' );
    $now = '2026-08-11T10:18:00Z';
    is( $http->( GET '/people', Cookie => "tira_session=$live" )->code, 200,
        'and nine minutes after that, because the action restarted the clock' );
    $now = '2026-08-11T10:28:01Z';
    is( $http->( GET '/people', Cookie => "tira_session=$live" )->code, 401,
        'but ten quiet minutes still end it' );

    # --- signing out -----------------------------------------------------

    my $out = $http->( POST '/logout', Content => '{}', Cookie => "tira_session=$live" );
    is( $out->code, 200, 'signing out works' );
    like( $out->header('Set-Cookie') // '', qr/tira_session=;|Max-Age=0|Expires=Thu, 01 Jan 1970/,
        'and the cookie is cleared rather than left in the browser' );
    is( $http->( GET '/data', Cookie => "tira_session=$live" )->code, 401,
        'after which the token is worth nothing' );

    # --- claiming a password on a first visit ----------------------------

    $tira->person_add( project => $root, id => 'grace', name => 'Grace' );
    my $claim = $http->( POST '/login', Content => '{"id":"grace","password":"first time"}' );
    is( $claim->code, 200, 'somebody who has never signed in claims a password by using it' );
    like( $claim->header('Set-Cookie') // '', qr/tira_session=/,
        'and is signed in straight away rather than typing it twice' );

    my $mistyped = $http->( POST '/login', Content => '{"id":"grace","password":"something else"}' );
    is( $mistyped->code, 401, 'and from then on it has to match' );

    # The title carries an em dash. This renderer has no `use utf8`, so the
    # only question that matters is whether what reaches the browser is the
    # character or two mangled bytes - and the answer has been wrong here
    # before, so it is checked on the wire rather than in the source.
    {
        my $served = $http->( GET '/' );
        like( $served->header('Content-Type'), qr/charset=UTF-8/i,
            'the login page says it is UTF-8' );
        my $bytes = $served->content;
        my $text = eval { Encode::decode( 'UTF-8', $bytes, Encode::FB_CROAK() ) };
        ok( defined $text, 'and its bytes really are valid UTF-8' );
        like( $text // '', qr/\x{2014}/, 'with the dash in the title intact rather than mangled' );
        is( ( $text // '' ) =~ tr/\x{00c3}\x{00e2}//, 0,
            'and carries none of the tell-tale bytes of a second encoding' );
    }

    # --- what the login page gives away ----------------------------------

    # A stranger reaching the front door must not learn who is on the project,
    # and a failed sign-in must not tell them whether the person exists.
    my $page = $http->( GET '/' )->content;
    like( $page, qr/<form|password/i,
        'the login page rendered - a page that failed to would name nobody either, '
          . 'and this check is the one that would have said so' );
    unlike( $page, qr/michael|grace|buildbot/, 'the login page names nobody' );

    my $unknown = decode_json( $http->( POST '/login',
        Content => '{"id":"nobody-at-all","password":"x"}' )->content );
    my $known = decode_json( $mistyped->content );
    is_deeply( $unknown, $known,
        'and an unknown person is answered exactly as a wrong password is' );
};

# --- a board that has lost its session -------------------------------------

# The board refreshes itself in the background. When the login gate went in, a
# page that was already open lost its session and every refresh came back
# refused - and the page, having nothing to do with a failure, kept drawing the
# cards it last managed to load. The owner photographed a board at five in the
# morning showing where things were the previous day, and nothing on screen
# said it was signed out.
{
    my @calls;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
            command => 'dashboard.ticket', tira => $tira,
            argv => [ '-o', 'browser' ],
            browser_server => sub { push @calls, {@_}; return 1 },
        ) };
    }
    my $html = $calls[0]{render}->();

    like( $html, qr/response\.status===401/,
        'the refresh notices when it is refused for want of a session' );
    like( $html, qr/response\.status===401\)\{location\.reload\(\)/,
        'and reloads, which is what puts the sign-in in front of the person' );

    # The refusal is a 401 rather than anything else, so the page above has
    # something to recognise. This is asserted from the gate's side too,
    # because the two halves are useless apart.
    test_psgi $app, sub {
        my ($http) = @_;
        my $refused = $http->( GET '/data?type=ticket' );
        is( $refused->code, 401, 'and the gate refuses a poll with exactly that' );
    };
}

done_testing;

__END__

=head1 NAME

77-login-gate.t - TKT-004 nothing but the login page without a session

=head1 DESCRIPTION

The owner asked that everyone lands on the login page until they are in, so
the front door serves the login rather than the board and every other route
refuses outright. Refusing with JSON rather than a page matters: the board
fetches these routes from its own scripts, and a login page rendered into a
card is worse than an error.

Every route is listed here by hand rather than derived from the application,
so a route added later without a thought for the gate shows up as a hole
instead of passing quietly.

The two answers that are easy to get wrong are checked at the seam where they
matter rather than in the engine. The board polls one route on a timer whether
anybody is there or not, so that poll must not keep a session alive - it is
checked by polling inside the window and showing the session still ends ten
minutes after the last real action. And a deliberate action must restart the
clock, so an afternoon of work is never interrupted.

The last section is about what a stranger can learn: the login page names
nobody, and a person who does not exist is answered exactly as a wrong
password is.

=cut
