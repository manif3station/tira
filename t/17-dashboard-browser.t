#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Request::Common qw(GET);
use JSON::PP qw(decode_json);
use Plack::Test;
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;

require Plack::Runner;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'browser' );
my $tira = Tira->new( clock => sub { '2026-08-06T14:00:00+0100' } );
$tira->create_project( name => 'Browser project', dir => $root );
$tira->create_record( project => $root, type => 'ticket', title => 'Live card' );

sub browser_cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err, @calls ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run(
        command => $command, argv => \@argv, tira => $tira,
        browser_server => sub { push @calls, { @_ }; return 1 },
    );
    return ( $status, $out, $err, \@calls );
}

my ( $status, $out, $err, $calls ) =
  browser_cli( 'dashboard.ticket', '--project', $root, '--title', '-o', 'browser' );
is( $status, 0, 'browser dashboard succeeds' );
is( $out, '', 'server mode does not dump HTML to stdout' );
is( $err, '', 'server mode has no stderr' );
is( $calls->[0]{host}, '0.0.0.0', 'browser defaults to all-interface host' );
is( $calls->[0]{port}, 7899, 'browser defaults to port 7899' );
my $live_html = $calls->[0]{render}->();
like( $live_html, qr/Live card/, 'server renderer retains title mode' );
like( $live_html, qr/fetch\("\/data".*updateBoards/s,
    'browser dashboard updates board positions from the JSON endpoint' );
unlike( $live_html, qr/setTimeout\(\(\)=>location\.reload/,
    'browser dashboard does not reload the whole page' );
like( $live_html, qr/<dialog class="card-dialog".*JSON\.stringify/s,
    'browser dashboard includes a full-record card dialog' );
my $browser_data = decode_json( $calls->[0]{data}->() );
is( $browser_data->{ticket}{backlog}[0]{title}, 'Live card',
    'browser data callback returns complete JSON records' );

( $status, $out, $err, $calls ) =
  browser_cli( 'dashboard.sow', '--project', $root, '-o', 'browser=127.0.0.1:4567' );
is( $status, 0, 'explicit browser endpoint succeeds' );
is( $calls->[0]{host}, '127.0.0.1', 'explicit host is retained' );
is( $calls->[0]{port}, 4567, 'explicit port is retained' );

for my $endpoint ( 'localhost', '0.0.0.0:1234' ) {
    ( $status, $out, $err, $calls ) =
      browser_cli( 'dashboard', '--project', $root, '-o', "browser=$endpoint" );
    is( $status, 0, "$endpoint is accepted" );
}

for my $endpoint ( 'example.com', 'localhost:0', 'localhost:65536', 'localhost:nope', '127.0.0.1:12:34' ) {
    ( $status, $out, $err, $calls ) =
      browser_cli( 'dashboard', '--project', $root, '-o', "browser=$endpoint" );
    is( $status, 2, "$endpoint is rejected" );
    is( scalar @{$calls}, 0, 'invalid endpoint starts no server' );
}

( $status, $out, $err, $calls ) =
  browser_cli( 'project.show', '--project', $root, '-o', 'browser' );
is( $status, 2, 'browser output is dashboard-only' );
like( $err, qr/Browser output is available only for dashboard commands/,
    'scope error is actionable' );

my $renders = 0;
my $app = Tira::DashboardWeb->build_psgi_app(
    render => sub { $renders++; return '<!doctype html><p>Live</p>' },
    data => sub { return '{"ticket":{"backlog":[]}}' },
);
test_psgi $app, sub {
    my ($client) = @_;
    my $response = $client->( GET '/?refresh=30' );
    is( $response->code, 200, 'PSGI root returns success' );
    like( $response->header('Content-Type'), qr{text/html}, 'PSGI response is HTML' );
    is( $response->content, '<!doctype html><p>Live</p>', 'PSGI returns rendered dashboard' );
    my $data_response = $client->( GET '/data?refresh=30' );
    is( $data_response->code, 200, 'PSGI data route returns success' );
    like( $data_response->header('Content-Type'), qr{application/json}, 'data response is JSON' );
    is( decode_json( $data_response->content )->{ticket}{backlog}[0] // 'empty', 'empty',
        'data route returns the supplied full dashboard payload' );
};
is( $renders, 1, 'PSGI renders afresh for each request' );

eval { Tira::DashboardWeb->build_psgi_app() };
like( $@, qr/Missing dashboard renderer/, 'PSGI builder requires a renderer' );
eval { Tira::DashboardWeb->build_psgi_app( render => sub { '' } ) };
like( $@, qr/Missing dashboard data provider/, 'PSGI builder requires a data provider' );

{
    no warnings 'redefine';
    my ( @options, $ran );
    local *Plack::Runner::new = sub { return bless {}, 'Plack::Runner' };
    local *Plack::Runner::parse_options = sub { shift; @options = @_ };
    local *Plack::Runner::run = sub { my ( $self, $served_app ) = @_; $ran = ref($served_app) eq 'CODE' };
    ok(
        Tira::DashboardWeb->serve(
            host => 'localhost', port => 4567,
            render => sub { '<!doctype html>' },
            data => sub { '{}' },
        ),
        'serve completes when its PSGI runner exits'
    );
    is_deeply(
        \@options,
        [ '--server', 'HTTP::Server::PSGI', '--host', 'localhost', '--port', 4567, '--env', 'deployment' ],
        'serve configures the requested PSGI listener'
    );
    ok( $ran, 'serve passes a PSGI application to the runner' );
}

{
    no warnings 'redefine';
    my %received;
    local *Tira::DashboardWeb::serve = sub { shift; %received = @_; return 1 };
    ok(
        Tira::CLI::_serve_browser(
            host => 'localhost', port => 7899,
            render => sub { '' }, data => sub { '{}' },
        ),
        'default browser adapter delegates to the Dancer2 server'
    );
    is( $received{port}, 7899, 'default browser adapter retains server arguments' );
}

{
    my ( $status, $out, $err, $calls );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    $status = Tira::CLI->run(
        command => 'dashboard', argv => [ '--project', $root, '-o', 'browser' ], tira => $tira,
        browser_server => sub { die "listener unavailable\n" },
    );
    is( $status, 2, 'server startup failure is structured' );
    like( $err, qr/listener unavailable/, 'server startup error is retained' );
}

done_testing;

__END__

=head1 NAME

17-dashboard-browser.t - Dancer2 browser output for Tira dashboards

=head1 DESCRIPTION

Guards browser endpoint parsing, dashboard-only scope, live rendering, and the
HTTP response contract of the Dancer2 PSGI application.

=cut
