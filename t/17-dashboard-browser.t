#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Encode qw(decode_utf8);
use HTTP::Request::Common qw(GET POST);
use Cpanel::JSON::XS qw(decode_json);
use Plack::Test;
use Test::More;

use lib 'lib', 't/lib';
use GatedApp qw(signed_in);
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;
# Tira::CLI::Serve holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Serve;

require Plack::Runner;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'browser' );
my $tira = Tira->new( clock => sub { '2026-08-06T14:00:00+0100' } );
$tira->create_project( name => 'Browser project', dir => $root );
$tira->person_add( project => $root, id => 'tester', name => 'Tester' );
$tira->create_record( project => $root, type => 'ticket', title => 'Live card' );

sub browser_cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err, @calls ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run(
        command => $command, argv => \@argv, tira => $tira,
        browser_server => sub { push @calls, { @_ }; return 1 },
    );
    return ( $status, $out, $err, \@calls );
}

my ( $status, $out, $err, $calls ) =
  browser_cli( 'dashboard.ticket', '--title', '-o', 'browser' );
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
    $calls->[0]{move}->( { type => 'ticket', ref => 'TKT-001', column => 'backlog', _signed_in => 'tester' } )
);
ok( $move_result->{ok}, 'browser move provider returns a successful mutation' );
is( decode_json( $calls->[0]{detail}->( { type => 'ticket', ref => 'TKT-001' } ) )->{ref},
    'TKT-001', 'browser detail provider returns one complete record' );

# --- TKT-532: the engine resolves a record by ref alone (_record_data walks
# every board's on-disk files for the matching filename); 'type' is never
# read for lookup, so the provider should not require it either. ------------
is( decode_json( $calls->[0]{detail}->( { ref => 'TKT-001' } ) )->{ref},
    'TKT-001', 'browser detail provider works with only a ref, no type' );
my $move_without_type = decode_json(
    $calls->[0]{move}->( { ref => 'TKT-001', column => 'backlog', _signed_in => 'tester' } )
);
ok( $move_without_type->{ok}, 'browser move provider works with only ref and column, no type' );

my $browser_data = decode_json( $calls->[0]{data}->() );
is( $browser_data->{ticket}{backlog}[0]{title}, 'Live card',
    'browser data callback returns complete JSON records' );

( $status, $out, $err, $calls ) =
  browser_cli( 'dashboard.sow', '-o', 'browser=127.0.0.1:4567' );
is( $status, 0, 'explicit browser endpoint succeeds' );
is( $calls->[0]{host}, '127.0.0.1', 'explicit host is retained' );
is( $calls->[0]{port}, 4567, 'explicit port is retained' );

for my $endpoint ( 'localhost', '0.0.0.0:1234' ) {
    ( $status, $out, $err, $calls ) =
      browser_cli( 'dashboard', '-o', "browser=$endpoint" );
    is( $status, 0, "$endpoint is accepted" );
}

for my $endpoint ( 'example.com', 'localhost:0', 'localhost:65536', 'localhost:nope', '127.0.0.1:12:34' ) {
    ( $status, $out, $err, $calls ) =
      browser_cli( 'dashboard', '-o', "browser=$endpoint" );
    is( $status, 2, "$endpoint is rejected" );
    is( scalar @{$calls}, 0, 'invalid endpoint starts no server' );
}

( $status, $out, $err, $calls ) =
  browser_cli( 'project.show', '-o', 'browser' );
is( $status, 2, 'browser output is dashboard/onboard-only' );
like( $err, qr/Browser output is available only for dashboard and onboard commands/,
    'scope error is actionable' );

my $renders = 0;
my $pound = chr 0xA3;
my $app = Tira::DashboardWeb->build_psgi_app(
    signed_in(),
    render => sub { $renders++; return '<!doctype html><p>Live ' . $pound . '</p>' },
    data => sub { return '{"ticket":{"backlog":[{"title":"\\u00a3"}]}}' },
    move => sub { return '{"ok":true}' },
    detail => sub { return '{"ref":"TKT-001","title":"\\u00a3"}' },
    search => sub { '[]' },
    police_log => sub { '[]' },
    policies => sub { '{"declared":[],"declined":[],"undeclared":[],"rules":{},"actions":[]}' },
    policy_add => sub { '{"ok":true}' },
    policy_remove => sub { '{"ok":true}' },
    policy_decline => sub { '{"ok":true}' },
    tasklist => sub { '[]' },
    tasklist_add => sub { '{}' },
    tasklist_update => sub { '{}' },
    tasklist_next => sub { '{}' },
    tasklist_shift => sub { '{}' },
    tasklist_pop => sub { '{}' },
    tasklist_unshift => sub { '{}' },
    tasklist_slice => sub { '{}' },
    tasklist_remove => sub { '{}' },
    tasklist_import => sub { '{}' },
    tasklist_prune => sub { '{}' },
    tasklist_task_attach_add => sub { '{}' },
    tasklist_task_attach_discard => sub { '{}' },
    tasklist_task_ref_link => sub { '{}' },
    tasklist_task_ref_unlink => sub { '{}' },
    tasklist_sessions => sub { '[]' },
    columns => sub { '[]' },
    question_answer => sub { '{"ok":true}' },
    question_mark => sub { '{"ok":true}' },
    question_attach => sub { '{"ok":true}' },
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
    attachment_discard => sub { '{"ok":true}' },
    checklist_add => sub { return '{"ok":true}' },
    checklist_update => sub { return '{"ok":true}' },
    required_action_update => sub { return '{"ok":true}' },
    link_types => sub { '[]' },
    hierarchy_link => sub { '{"ok":true}' },
    hierarchy_unlink => sub { '{"ok":true}' },
    subitem_link => sub { '{"ok":true}' },
    subitem_unlink => sub { '{"ok":true}' },
    link_add => sub { '{"ok":true}' },
    link_remove => sub { '{"ok":true}' },
    police_log => sub { '[]' },
    policies => sub { '{"declared":[],"declined":[],"undeclared":[],"rules":{},"actions":[]}' },
    policy_add => sub { '{"ok":true}' },
    policy_remove => sub { '{"ok":true}' },
    policy_decline => sub { '{"ok":true}' },
    tasklist => sub { '[]' },
    tasklist_add => sub { '{}' },
    tasklist_update => sub { '{}' },
    tasklist_next => sub { '{}' },
    tasklist_shift => sub { '{}' },
    tasklist_pop => sub { '{}' },
    tasklist_unshift => sub { '{}' },
    tasklist_slice => sub { '{}' },
    tasklist_remove => sub { '{}' },
    tasklist_import => sub { '{}' },
    tasklist_prune => sub { '{}' },
    tasklist_task_attach_add => sub { '{}' },
    tasklist_task_attach_discard => sub { '{}' },
    tasklist_task_ref_link => sub { '{}' },
    tasklist_task_ref_unlink => sub { '{}' },
    tasklist_sessions => sub { '[]' },
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
    is( decode_json( $move_response->content )->{ok}, Cpanel::JSON::XS::true,
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
    # A path, not a coderef, and a board to serve.
    #
    # This asserted that serve() hands Plack::Runner an application already
    # built, which is what it did and what stopped a served board picking up
    # new code: an app built in the launching process is in memory before
    # Starman forks, so re-forked workers inherit it and a HUP reloads nothing.
    # Since 2.00 the runner is handed the path to dashboard.psgi, which each
    # worker loads for itself - so the assertion moves with the design rather
    # than being deleted, and serve() now needs to know which board, because
    # the workers cannot be handed a closure over it.
    local *Plack::Runner::run = sub { my ( $self, $served_app ) = @_; $ran = !ref($served_app) && $served_app =~ /dashboard\.psgi\z/ };
    ok(
        Tira::DashboardWeb->serve(
            host => 'localhost', port => 4567, project => $root,
            police_log => sub { '[]' },
    policies => sub { '{"declared":[],"declined":[],"undeclared":[],"rules":{},"actions":[]}' },
    policy_add => sub { '{"ok":true}' },
    policy_remove => sub { '{"ok":true}' },
    policy_decline => sub { '{"ok":true}' },
    tasklist => sub { '[]' },
    tasklist_add => sub { '{}' },
    tasklist_update => sub { '{}' },
    tasklist_next => sub { '{}' },
    tasklist_shift => sub { '{}' },
    tasklist_pop => sub { '{}' },
    tasklist_unshift => sub { '{}' },
    tasklist_slice => sub { '{}' },
    tasklist_remove => sub { '{}' },
    tasklist_import => sub { '{}' },
    tasklist_prune => sub { '{}' },
    tasklist_task_attach_add => sub { '{}' },
    tasklist_task_attach_discard => sub { '{}' },
    tasklist_task_ref_link => sub { '{}' },
    tasklist_task_ref_unlink => sub { '{}' },
    tasklist_sessions => sub { '[]' },
            signed_in(),
            render => sub { '<!doctype html>' },
            data => sub { '{}' },
            move => sub { '{}' },
            detail => sub { '{}' },
            search => sub { '[]' },
            columns => sub { '[]' },
    question_answer => sub { '{"ok":true}' },
    question_mark => sub { '{"ok":true}' },
    question_attach => sub { '{"ok":true}' },
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
            attachment_discard => sub { '{"ok":true}' },
            checklist_add => sub { '{}' },
            checklist_update => sub { '{}' },
            required_action_update => sub { '{}' },
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
    # Starman rather than HTTP::Server::PSGI, and with workers. The single
    # connection server stopped answering entirely while one connection was
    # held open - his board was found listening, its process alive, and
    # returning nothing at all, which looks exactly like a board that is fine
    # until somebody tries to load it.
    is_deeply(
        \@options,
        [ '--server', 'Starman', '--workers', 5, '--host', 'localhost', '--port', 4567, '--env', 'deployment' ],
        'serve configures a listener that keeps answering while one connection is slow'
    );
    ok( $ran, 'serve passes a PSGI application to the runner' );
}

{
    no warnings 'redefine';
    my %received;
    local *Tira::DashboardWeb::serve = sub { shift; %received = @_; return 1 };
    ok(
        Tira::CLI::Serve::_serve_browser(
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
    $status = do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
        command => 'dashboard', argv => [ '-o', 'browser' ], tira => $tira,
        browser_server => sub { die "listener unavailable\n" },
    ) };
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
