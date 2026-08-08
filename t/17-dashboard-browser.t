#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Encode qw(decode_utf8);
use HTTP::Request::Common qw(GET POST);
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
like( $live_html, qr/<h1>Browser project<\/h1>/, 'the hero shows the project name' );
like( $live_html, qr/Tira Kanban/, 'the product name remains visible' );
like( $live_html, qr/fetch\("\/data".*updateBoards/s,
    'browser dashboard updates board positions from the JSON endpoint' );
like( $live_html, qr/fetch\("\/record\?type=".*renderCard/s,
    'browser dashboard lazy-loads full card details on click' );
unlike( $live_html, qr/setTimeout\(\(\)=>location\.reload/,
    'browser dashboard does not reload the whole page' );
like( $live_html, qr/<dialog class="card-dialog".*card-dialog__sections/s,
    'browser dashboard includes a sectioned card dialog' );
like( $live_html, qr/pointerdown.*pointerup.*\/move/s,
    'browser dashboard exposes pointer-based drag and drop move behavior' );
like( $live_html, qr/touchmove.*preventDefault.*passive:false/s,
    'an armed drag blocks native touch scrolling so iOS tracks the ghost' );
unlike( $live_html, qr/dragstart|draggable="true"/,
    'the HTML5 drag path is fully replaced' );
ok( ref $calls->[0]{move} eq 'CODE', 'browser server receives a move provider' );
ok( ref $calls->[0]{detail} eq 'CODE', 'browser server receives a detail provider' );
my $move_result = decode_json(
    $calls->[0]{move}->( { type => 'ticket', ref => 'TKT-001', column => 'backlog' } )
);
ok( $move_result->{ok}, 'browser move provider returns a successful mutation' );
is( decode_json( $calls->[0]{detail}->( { type => 'ticket', ref => 'TKT-001' } ) )->{ref},
    'TKT-001', 'browser detail provider returns one complete record' );
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
my $pound = chr 0xA3;
my $app = Tira::DashboardWeb->build_psgi_app(
    render => sub { $renders++; return '<!doctype html><p>Live ' . $pound . '</p>' },
    data => sub { return '{"ticket":{"backlog":[{"title":"\\u00a3"}]}}' },
    move => sub { return '{"ok":true}' },
    detail => sub { return '{"ref":"TKT-001","title":"\\u00a3"}' },
    search => sub { '[]' },
    columns => sub { '[]' },
    column_apply => sub { '{}' },
    create => sub { '{"ok":true,"record":{"ref":"TKT-009"}}' },
    update => sub { return '{"ok":true}' },
    comment_add => sub { return '{"ok":true}' },
    comment_update => sub { return '{"ok":true}' },
    comment_remove => sub { return '{"ok":true}' },
    people => sub { return '[]' },
    attachment_fetch => sub { return { content => '', content_type => 'text/plain; charset=UTF-8', filename => 'x.txt', inline => 1 } },
    attachment_add => sub { return '{"ok":true}' },
    attachment_remove => sub { return '{"ok":true}' },
    checklist_add => sub { return '{"ok":true}' },
    checklist_update => sub { return '{"ok":true}' },
    link_types => sub { '[]' },
    hierarchy_link => sub { '{"ok":true}' },
    hierarchy_unlink => sub { '{"ok":true}' },
    subitem_link => sub { '{"ok":true}' },
    subitem_unlink => sub { '{"ok":true}' },
    link_add => sub { '{"ok":true}' },
    link_remove => sub { '{"ok":true}' },
);
my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    test_psgi $app, sub {
    my ($client) = @_;
    my $response = $client->( GET '/?refresh=30' );
    is( $response->code, 200, 'PSGI root returns success' );
    like( $response->header('Content-Type'), qr{text/html}, 'PSGI response is HTML' );
    is( decode_utf8( $response->content ), '<!doctype html><p>Live ' . $pound . '</p>',
        'PSGI returns UTF-8 rendered dashboard bytes' );
    my $data_response = $client->( GET '/data?refresh=30' );
    is( $data_response->code, 200, 'PSGI data route returns success' );
    like( $data_response->header('Content-Type'), qr{application/json}, 'data response is JSON' );
    is( decode_json( $data_response->content )->{ticket}{backlog}[0]{title}, $pound,
        'data route returns UTF-8 JSON bytes' );
    my $move_response = $client->(
        POST '/move', Content_Type => 'application/json', Content => '{"type":"ticket","ref":"TKT-001","column":"done"}'
    );
    is( $move_response->code, 200, 'PSGI move route returns success' );
    is( decode_json( $move_response->content )->{ok}, JSON::PP::true,
        'move route returns the provider result' );
    my $detail_response = $client->( GET '/record?type=ticket&ref=TKT-001' );
    is( $detail_response->code, 200, 'PSGI detail route returns success' );
    is( decode_json( $detail_response->content )->{title}, $pound,
        'detail route returns the clicked record payload' );
    };
}
is( scalar @warnings, 0, 'PSGI emits no implicit wide-character warnings' );
is( $renders, 1, 'PSGI renders afresh for each request' );

eval { Tira::DashboardWeb->build_psgi_app() };
like( $@, qr/Missing dashboard renderer/, 'PSGI builder requires a renderer' );
eval { Tira::DashboardWeb->build_psgi_app( render => sub { '' } ) };
like( $@, qr/Missing dashboard data provider/, 'PSGI builder requires a data provider' );
eval { Tira::DashboardWeb->build_psgi_app( render => sub { '' }, data => sub { '{}' } ) };
like( $@, qr/Missing dashboard move provider/, 'PSGI builder requires a move provider' );
eval { Tira::DashboardWeb->build_psgi_app( render => sub { '' }, data => sub { '{}' }, move => sub { '{}' } ) };
like( $@, qr/Missing dashboard detail provider/, 'PSGI builder requires a detail provider' );

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
            move => sub { '{}' },
            detail => sub { '{}' },
            search => sub { '[]' },
            columns => sub { '[]' },
            column_apply => sub { '{}' },
            create => sub { '{}' },
            update => sub { '{}' },
            comment_add => sub { '{}' },
            comment_update => sub { '{}' },
            comment_remove => sub { '{}' },
            people => sub { '[]' },
            attachment_fetch => sub { return {} },
            attachment_add => sub { '{}' },
            attachment_remove => sub { '{}' },
            checklist_add => sub { '{}' },
            checklist_update => sub { '{}' },
            link_types => sub { '[]' },
            hierarchy_link => sub { '{"ok":true}' },
            hierarchy_unlink => sub { '{"ok":true}' },
            subitem_link => sub { '{"ok":true}' },
            subitem_unlink => sub { '{"ok":true}' },
            link_add => sub { '{"ok":true}' },
            link_remove => sub { '{"ok":true}' },
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

Guards browser endpoint parsing, dashboard-only scope, live rendering, lazy
detail/move routes, UTF-8 response bytes, and the HTTP contract of the Dancer2
PSGI application.

=cut
