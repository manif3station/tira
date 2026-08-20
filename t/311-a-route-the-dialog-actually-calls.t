#!/usr/bin/env perl
# The card dialog's new required-actions section (TKT-440) marks an item done
# through a real HTTP route, not a stub - /required-action/update, wired to
# required_item_update the same way /checklist/update is wired to
# checklist_update. Exercised here end to end, through the actual
# browser_providers() the dashboard builds, so the provider closure itself -
# not a hand-written substitute - is what runs.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Request::Common qw(POST);
use Cpanel::JSON::XS ();
use Plack::Test;
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'project' );

my $tira = Tira->new;
$tira->project_new(
    name => 'Routed', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning' ],
    sow_prefix => 'RTS', epic_prefix => 'RTE', ticket_prefix => 'RTT',
);
$tira->login_register( project => $root, id => 'claude', password => 'hunter2' );
$tira->column_update( project => $root, type => 'ticket', name => 'planning', required_action => ['left a note'] );

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Routed card', column => 'planning' );

# create_record is a direct engine call, exempt from the CLI-only
# creation-time population (TKT-439/445) - added directly here, as the test
# setup rather than the thing under test.
my $item = $tira->required_item_add(
    project => $root, ref => $card->{ref}, item => 'left a note', status => 'pending', column => 'planning' );

my $app = Tira::DashboardWeb->build_psgi_app(
    Tira::CLI::browser_providers( tira => $tira, project => $root ),
    render => sub { '<!doctype html><p>board</p>' },
    data => sub { '{"ticket":{"backlog":[]}}' },
);

test_psgi $app, sub {
    my ($http) = @_;

    my $login = $http->( POST '/login', Content => '{"id":"claude","password":"hunter2"}' );
    my ($token) = ( $login->header('Set-Cookie') // '' ) =~ /tira_session=([^;]+)/;
    ok( $token, 'signed in' );
    my $cookie = "tira_session=$token";

    my $response = $http->( POST '/required-action/update', Cookie => $cookie,
        Content => Cpanel::JSON::XS->new->encode(
            { type => 'ticket', ref => $card->{ref}, id => $item->{id}, status => 'done' } ) );
    is( $response->code, 200, 'the real route succeeds' ) or diag( $response->content );
    my $decoded = Cpanel::JSON::XS->new->decode( $response->content );
    ok( $decoded->{ok}, 'and reports ok' );
    is( $decoded->{entry}{status}, 'done', 'and returns the updated entry' );

    my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
    my ($updated) = grep { $_->{id} eq $item->{id} } @{ $shown->{required_items} };
    is( $updated->{status}, 'done', 'and the card is actually updated, not just the response' );

    # --- the same guard every other mutation route already has -----------
    my $bad = $http->( POST '/required-action/update', Cookie => $cookie,
        Content => Cpanel::JSON::XS->new->encode( { type => 'ticket', ref => $card->{ref} } ) );
    isnt( $bad->code, 200, 'missing id is refused, the same as a malformed checklist/update' );
};

done_testing;

__END__

=head1 NAME

311-a-route-the-dialog-actually-calls.t - /required-action/update runs the real provider, not a stub

=head1 DESCRIPTION

Covers TKT-440's server-side half: the required_action_update provider
closure in browser_providers() (lib/Tira/CLI.pm) is wired to
/required-action/update in DashboardWeb.pm and actually calls
required_item_update, exercised here through a real PSGI app built the same
way the dashboard's own entry point builds it - every other dashboard test
that constructs its own stub providers hash does not exercise this closure's
body at all.

=cut
