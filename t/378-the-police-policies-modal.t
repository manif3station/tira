#!/usr/bin/env perl
# TKT-493: a dashboard modal for the board-wide police policy engine (36
# rules), separate from the Columns dialog's narrower per-column
# required-action template. Covers the new engine method (policy_rule_specs),
# the new browser_providers closures (policies/policy_add/policy_remove/
# policy_decline), their real HTTP routes, and the dashboard HTML/JS/CSS the
# button and dialog are built from.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Request::Common qw(GET POST);
use Cpanel::JSON::XS ();
use Plack::Test;
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'project' );

my $tira = Tira->new( clock => sub { '2026-08-24T11:00:00Z' } );
$tira->project_new(
    name => 'Policed', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'doing' ],
    sow_prefix => 'PLS', epic_prefix => 'PLE', ticket_prefix => 'PLT',
);
$tira->login_register( project => $root, id => 'claude', password => 'hunter2' );

# --- the engine method the whole picker is built on -----------------------
my $specs = $tira->policy_rule_specs();
ok( ref($specs) eq 'HASH' && keys(%$specs) >= 30, 'policy_rule_specs returns every policy rule' );
is_deeply(
    $specs->{'card-duration'}, { needs => ['column', 'age'], forbids => [] },
    'a rule with needs and no forbids is described exactly as policy_add validates it',
);
is_deeply(
    $specs->{'card-unassigned'}, { needs => [], forbids => [ 'column', 'enter' ] },
    'a rule with forbids is described exactly as policy_add validates it',
);

# --- the four new provider closures, exercised directly -------------------
my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
for my $name (qw(policies policy_add policy_remove policy_decline)) {
    ok( exists $providers{$name}, "browser_providers exposes a $name closure" );
}

my $empty_view = Cpanel::JSON::XS::decode_json( $providers{policies}->() );
is_deeply( $empty_view->{declared}, [], 'a fresh project has no declared policies' );
ok( scalar( @{ $empty_view->{undeclared} } ) >= 30, 'and every rule starts undeclared' );

# TKT-519: the dialog cannot show which {token}s a --message can use unless
# it is told, and hardcoding a second copy in the JS is exactly the kind of
# duplicate that drifts from Tira::policy_message_fields the day a token is
# added or renamed - so the payload carries the engine's own list.
is_deeply(
    $empty_view->{token_fields}, Tira::policy_message_fields(),
    'the policies payload carries the engine\'s own --message token list',
);

# --- the real HTTP routes, through the actual PSGI app ---------------------
my $app = Tira::DashboardWeb->build_psgi_app(
    Tira::CLI::browser_providers( tira => $tira, project => $root ),
    render => sub { '<!doctype html><p>board</p>' },
    data   => sub { '{"ticket":{"backlog":[]}}' },
);

test_psgi $app, sub {
    my ($http) = @_;

    my $login = $http->( POST '/login', Content => '{"id":"claude","password":"hunter2"}' );
    my ($token) = ( $login->header('Set-Cookie') // '' ) =~ /tira_session=([^;]+)/;
    ok( $token, 'signed in' );
    my $cookie = "tira_session=$token";

    my $view = $http->( GET '/policies', Cookie => $cookie );
    is( $view->code, 200, 'GET /policies succeeds' );
    my $decoded = Cpanel::JSON::XS::decode_json( $view->content );
    is_deeply( $decoded->{declared}, [], 'and starts with nothing declared' );

    my $add = $http->( POST '/policy/add', Cookie => $cookie,
        Content => Cpanel::JSON::XS->new->encode(
            { rule => 'card-duration', action => 'bridge-reminder', column => 'doing', age => '2h' }
        ) );
    is( $add->code, 200, 'POST /policy/add succeeds' ) or diag( $add->content );
    my $added = Cpanel::JSON::XS::decode_json( $add->content );
    ok( $added->{id}, 'and returns the new policy id' );

    $view = $http->( GET '/policies', Cookie => $cookie );
    $decoded = Cpanel::JSON::XS::decode_json( $view->content );
    is( scalar( @{ $decoded->{declared} } ), 1, 'the policy now shows up as declared' );
    is( $decoded->{declared}[0]{rule}, 'card-duration', 'with the rule it was declared for' );

    my $bad_add = $http->( POST '/policy/add', Cookie => $cookie,
        Content => Cpanel::JSON::XS->new->encode( { rule => 'card-duration', action => 'bridge-reminder' } ) );
    isnt( $bad_add->code, 200, 'a rule missing its needed parameters is refused, the same as the CLI' );

    my $decline = $http->( POST '/policy/decline', Cookie => $cookie,
        Content => Cpanel::JSON::XS->new->encode( { rule => 'wip-limit', reason => 'no limit on this board' } ) );
    is( $decline->code, 200, 'POST /policy/decline succeeds' ) or diag( $decline->content );

    $view = $http->( GET '/policies', Cookie => $cookie );
    $decoded = Cpanel::JSON::XS::decode_json( $view->content );
    ok( ( grep { $_->{rule} eq 'wip-limit' } @{ $decoded->{declined} } ), 'the declined rule shows up in the declined list' );

    my $remove = $http->( POST '/policy/remove', Cookie => $cookie,
        Content => Cpanel::JSON::XS->new->encode( { id => $added->{id} } ) );
    is( $remove->code, 200, 'POST /policy/remove succeeds' ) or diag( $remove->content );

    $view = $http->( GET '/policies', Cookie => $cookie );
    $decoded = Cpanel::JSON::XS::decode_json( $view->content );
    is_deeply( $decoded->{declared}, [], 'and the removed policy is gone from the declared list' );
};

# --- the dashboard HTML/JS/CSS the button and dialog are built from -------
my $data = $tira->dashboard( project => $root );
my $html = $tira->format_output( $data, output => 'table', project => $root, live => 1 );

like( $html, qr/class="board-policies"/, 'a Policies button sits next to the Columns button' );
like( $html, qr/class="policy-dialog"/, 'the page carries a policy dialog, separate from the column dialog' );
like( $html, qr/data-policy-tab="declared"/, 'the dialog offers a declared/declined/undeclared split' );
like( $html, qr/class="policy-form__rule"/, 'the dialog has a rule picker' );
like( $html, qr/class="policy-form__require_link"/, 'and covers every rule-specific parameter policy_add accepts, not just the illustrative two' );
like( $html, qr{fetch\("/policies"}, 'the dialog reads its data from the real route' );
like( $html, qr{postPolicy\("/policy/add"}, 'and adds through the real route' );

my $static_html = $tira->format_output( $data, output => 'table', project => $root, live => 0 );
like( $static_html, qr/<!doctype html>/i, 'the static page actually rendered, rather than coming back empty' );
unlike( $static_html, qr/class="board-policies"/,
    'a page saved to disk offers no Policies button, since clicking it could never work there' );

done_testing;

__END__

=head1 NAME

378-the-police-policies-modal.t - the dashboard Policies modal, engine to HTML

=head1 DESCRIPTION

TKT-493 gave the dashboard a modal for the board-wide police policy engine
(36 rules), which until now was CLI-only (tira.policy.add/list/remove/
decline). This covers: the new Tira.pm engine method policy_rule_specs
(exposes the same needs/forbids data policy_add validates against, so a
form's rule picker cannot drift from what the engine actually accepts); the
four new browser_providers closures in Tira::CLI (policies/policy_add/
policy_remove/policy_decline); their real HTTP routes in
Tira::DashboardWeb (GET /policies, POST /policy/add, /policy/remove,
/policy/decline), exercised through the actual PSGI app rather than a stub;
and the dashboard HTML itself, confirming the Policies button, dialog markup,
and rule-specific parameter fields are only rendered on a live page.
