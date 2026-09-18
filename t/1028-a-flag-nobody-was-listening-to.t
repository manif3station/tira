#!/usr/bin/env perl
# TKT-1028, Q-173 (Michael's own answer): "wire it up" - with_police and
# with_policy_bridge were passed all the way into DashboardWeb->serve and
# read nowhere past there (confirmed live via grep in a developer-dashboard
# container). A served page now shows a visible indicator when either is
# genuinely running beside it, the same way with_title already travels from
# the CLI to a worker through the environment (TIRA_DASHBOARD_TITLE) since a
# worker starts fresh and cannot be handed a closure over any of this.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Request::Common qw(GET POST);
use Cpanel::JSON::XS qw(decode_json);
use Plack::Test;
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'served' );
my $tira = Tira->new( clock => sub {'2026-09-18T08:00:00Z'} );
$tira->project_new(
    name => 'Served', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
);
$tira->create_record( project => $root, type => 'ticket', title => 'Watched card' );

# --- the unit-level claim: format_output itself, no server involved ---------

my $data = $tira->dashboard( project => $root, summary => 1 );
my $neither = $tira->format_output( $data, output => 'table', project => $root );
like( $neither, qr/\A<!doctype html>/i, 'the baseline page is a real rendered board, not an empty string' );
unlike( $neither, qr/Police running beside this board/,
    'with neither flag, the page carries no police indicator' );
unlike( $neither, qr/Policy bridge running beside this board/,
    'nor a policy-bridge one' );

my $police_only = $tira->format_output(
    $data, output => 'table', project => $root, with_police => 1 );
like( $police_only, qr/dashboard-indicator--police/, 'with_police alone renders the police indicator' );
unlike( $police_only, qr/dashboard-indicator--policy-bridge/, 'and not the policy-bridge one' );
like( $police_only, qr/Police running beside this board/,
    'the indicator says, in plain words, that police is running beside this board' );

my $both = $tira->format_output(
    $data, output => 'table', project => $root,
    with_police => 1, with_policy_bridge => 1 );
like( $both, qr/dashboard-indicator--police/, 'both flags render the police indicator' );
like( $both, qr/dashboard-indicator--policy-bridge/, 'and the policy-bridge indicator' );
like( $both, qr/Policy bridge running beside this board/, 'in plain words, for the bridge too' );

# --- the end-to-end claim: dashboard.psgi, the file each worker loads -------
#
# with_title already proved this same shape works (t/212 loads the file the
# same way) - this proves the two new env vars actually reach a live served
# page's HTML, not merely that DashboardWeb->serve sets them, since setting
# an environment variable nothing downstream reads is exactly the fault this
# ticket is about.

{
    local $ENV{TIRA_DASHBOARD_ROOT}          = $root;
    local $ENV{TIRA_DASHBOARD_TYPE}          = '';
    local $ENV{TIRA_DASHBOARD_TITLE}         = '0';
    local $ENV{TIRA_DASHBOARD_POLICE}        = '1';
    local $ENV{TIRA_DASHBOARD_POLICY_BRIDGE} = '0';

    my $app = do './dashboard.psgi';
    ok( !$@, 'the application still builds from the environment alone' ) or diag $@;

    test_psgi $app, sub {
        my ($client) = @_;

        # The board sits behind a login (TKT-004) - a real one here, since
        # dashboard.psgi always wires the engine's own providers, not a
        # test double. "Whatever you type becomes your password" (the login
        # page's own note) claims it on first use for a registered person.
        my $login = $client->( POST '/login',
            'Content-Type' => 'application/json',
            Content        => '{"id":"claude","password":"t3st-pass"}' );
        is( $login->code, 200, 'signing in as a registered project person succeeds' );
        my ($cookie) = $login->header('Set-Cookie') =~ /\A([^;]+)/;
        ok( $cookie, 'the sign-in leaves a session cookie to carry' );

        my $response = $client->( GET '/', Cookie => $cookie );
        is( $response->code, 200, 'the served page answers, signed in' );
        like( $response->content, qr/Police running beside this board/,
            'a real request to the real worker shows the police indicator, from the environment alone' );
        unlike( $response->content, qr/Policy bridge running beside this board/,
            'and not the policy-bridge one, since that env var was left at 0' );
    };
}

# --- CODEX REVIEW: a failed spawn must not claim to be running --------------
#
# tira.dashboard --with-police still serves the board even when the police
# pass itself could not be started ("the board is still worth serving
# without the bridge", _spawn_beside_board_if_requested's own comment) - so
# the CLI layer must pass what actually started, not what was merely asked
# for, into DashboardWeb->serve. The first draft passed $option{with_police}
# unconditionally and would have shown "Police running beside this board"
# for a police pass that never started.
{
    my @calls;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    local *STDOUT = $so;
    local *STDERR = $se;
    local $ENV{TIRA_HOME} = $root;
    Tira::CLI->run(
        command        => 'dashboard.ticket',
        tira           => $tira,
        argv           => [ '-o', 'browser', '--with-police', '--with-policy-bridge' ],
        browser_server => sub { push @calls, {@_}; return 1 },
        police_starter        => sub { return undef },
        policy_bridge_starter => sub { return undef },
    );
    is( scalar @calls, 1, 'the board was still served despite both spawns failing' );
    is( $calls[0]{with_police}, 0,
        'with_police reaches serve() as 0 when the police pass never actually started, not 1 because it was asked for' );
    is( $calls[0]{with_policy_bridge}, 0,
        'same for with_policy_bridge' );
}

done_testing;

__END__

=head1 NAME

1028-a-flag-nobody-was-listening-to.t - with_police/with_policy_bridge, shown rather than swallowed

=head1 DESCRIPTION

C<tira.dashboard --with-police>/C<--with-policy-bridge> passed a flag all
the way into C<DashboardWeb-E<gt>serve> that nothing downstream ever read -
confirmed by grep, live, in a developer-dashboard container. Michael's own
answer to Q-173 was to wire it up: a served page now shows a visible
indicator, via C<TIRA_DASHBOARD_POLICE>/C<TIRA_DASHBOARD_POLICY_BRIDGE>
travelling the same way C<TIRA_DASHBOARD_TITLE> already does, since a
worker starts fresh and cannot be handed a closure over any of this.

=cut
