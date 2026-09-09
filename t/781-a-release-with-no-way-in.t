#!/usr/bin/env perl
# lib/Tira/DashboardWeb.pm's @PROVIDERS list wires 40+ CLI capabilities into
# the browser dashboard - comments, attachments, checklist, required-actions,
# tasklist, policies, hierarchy/subitem links, login/session - but had zero
# entries for gate, evidence, or release_record, even though the project's
# own pending-push/push gate depends on exactly those fields. A person
# working only from the browser dashboard could not complete a card's
# release gate at all.
#
# Exercised the same way t/311 already proved required_action_update: real
# routes on a real Plack::Test app, built from the actual providers() the
# dashboard uses - not a hand-written substitute.
#
# WRITTEN RED.

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
    name => 'Released', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'verify' ],
    sow_prefix => 'RLS', epic_prefix => 'RLE', ticket_prefix => 'RLT',
);
$tira->login_register( project => $root, id => 'claude', password => 'hunter2' );

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Released card', column => 'verify' );

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

    # --- gate/add ------------------------------------------------------------

    my $gate_response = $http->( POST '/gate/add', Cookie => $cookie,
        Content => Cpanel::JSON::XS->new->encode(
            { type => 'ticket', ref => $card->{ref}, gate => 'verify', result => 'pass', details => 'suite green' } ) );
    is( $gate_response->code, 200, 'the real gate/add route succeeds' ) or diag( $gate_response->content );
    my $gate_decoded = Cpanel::JSON::XS->new->decode( $gate_response->content );
    ok( $gate_decoded->{ok}, 'and reports ok' );
    is( $gate_decoded->{entry}{result}, 'pass', 'and returns the recorded gate entry' );

    # --- gate/annotate ---------------------------------------------------------

    my $gate_annotate_response = $http->( POST '/gate/annotate', Cookie => $cookie,
        Content => Cpanel::JSON::XS->new->encode(
            { type => 'ticket', ref => $card->{ref}, id => $gate_decoded->{entry}{id}, note => 'looked again, still passes' } ) );
    is( $gate_annotate_response->code, 200, 'the real gate/annotate route succeeds' ) or diag( $gate_annotate_response->content );
    my $gate_annotate_decoded = Cpanel::JSON::XS->new->decode( $gate_annotate_response->content );
    ok( $gate_annotate_decoded->{ok}, 'and reports ok' );
    is( $gate_annotate_decoded->{annotation}{note}, 'looked again, still passes', 'and returns the recorded annotation' );

    # --- evidence/add ----------------------------------------------------------

    my $evidence_response = $http->( POST '/evidence/add', Cookie => $cookie,
        Content => Cpanel::JSON::XS->new->encode(
            { type => 'ticket', ref => $card->{ref}, summary => 'the suite passes clean' } ) );
    is( $evidence_response->code, 200, 'the real evidence/add route succeeds' ) or diag( $evidence_response->content );
    my $evidence_decoded = Cpanel::JSON::XS->new->decode( $evidence_response->content );
    ok( $evidence_decoded->{ok}, 'and reports ok' );
    is( $evidence_decoded->{entry}{summary}, 'the suite passes clean', 'and returns the recorded evidence entry' );

    # --- evidence/annotate -------------------------------------------------------

    my $evidence_annotate_response = $http->( POST '/evidence/annotate', Cookie => $cookie,
        Content => Cpanel::JSON::XS->new->encode(
            { type => 'ticket', ref => $card->{ref}, id => $evidence_decoded->{entry}{id}, note => 'reviewed the logs' } ) );
    is( $evidence_annotate_response->code, 200, 'the real evidence/annotate route succeeds' ) or diag( $evidence_annotate_response->content );
    my $evidence_annotate_decoded = Cpanel::JSON::XS->new->decode( $evidence_annotate_response->content );
    ok( $evidence_annotate_decoded->{ok}, 'and reports ok' );
    is( $evidence_annotate_decoded->{annotation}{note}, 'reviewed the logs', 'and returns the recorded annotation' );

    # --- release/record ----------------------------------------------------------

    my $release_response = $http->( POST '/release/record', Cookie => $cookie,
        Content => Cpanel::JSON::XS->new->encode(
            { type => 'ticket', ref => $card->{ref}, gate => 'verify', result => 'pass',
              details => 'suite green', evidence => 'prove -lr t clean', fix_version => '5.88' } ) );
    is( $release_response->code, 200, 'the real release/record route succeeds' ) or diag( $release_response->content );
    my $release_decoded = Cpanel::JSON::XS->new->decode( $release_response->content );
    ok( $release_decoded->{ok}, 'and reports ok' );

    # --- the record actually changed, not just the response ---------------

    my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
    is( scalar @{ $shown->{gate_passing_log} }, 2, 'two gate entries are recorded (gate/add and release/record)' );
    is( scalar @{ $shown->{evidence} }, 2, 'two evidence entries are recorded (evidence/add and release/record)' );
    is( $shown->{fix_version}, '5.88', 'and the fix version was set' );

    # --- a release from the CLI produces the same shape --------------------

    my $cli_card = $tira->create_record( project => $root, type => 'ticket', title => 'CLI card', column => 'verify' );
    $tira->release_record(
        project => $root, ref => $cli_card->{ref}, author => 'claude',
        gate => 'verify', result => 'pass', details => 'suite green',
        evidence => 'prove -lr t clean', fix_version => '5.88',
    );
    my $cli_shown = $tira->record_show( project => $root, ref => $cli_card->{ref} );
    is( $cli_shown->{fix_version}, $shown->{fix_version}, 'a CLI-recorded release matches the browser-recorded shape (fix_version)' );
    is( scalar @{ $cli_shown->{gate_passing_log} }, 1, 'a CLI-recorded release matches the browser-recorded shape (one gate entry from release_record alone)' );

    # --- the same guard every other mutation route already has -------------

    my $bad = $http->( POST '/gate/add', Cookie => $cookie,
        Content => Cpanel::JSON::XS->new->encode( { type => 'ticket', ref => $card->{ref} } ) );
    isnt( $bad->code, 200, 'a malformed gate/add is refused, the same as a malformed checklist/update' );
};

done_testing;

__END__

=head1 NAME

t/781-a-release-with-no-way-in.t - the browser dashboard can record a gate
result, evidence, and a release, without dropping to the CLI

=head1 DESCRIPTION

TKT-781. C<@PROVIDERS> in C<lib/Tira/DashboardWeb.pm> had no entries for
C<gate_add>, C<evidence_add>, or C<release_record>, even though the CLI
side (C<tira.gate.add>, C<tira.evidence.add>, C<tira.release.record>) was
fully built and load-bearing at this project's own pending-push/push gate.
C<gate_list>/C<evidence_list> were never wired as separate routes either
way - like C<checklist_list>, the same data already arrives on every
C<record_show>/detail fetch the dialog already makes, so a separate read
route would duplicate rather than add a capability. New POST routes -
C</gate/add>, C</evidence/add>, C</release/record> (plus C</gate/annotate>
and C</evidence/annotate>) - reach the same engine methods the CLI calls,
proven here through the actual C<Tira::CLI::browser_providers()> the
dashboard is built from, the same way C<t/311> already proved
C<required_action_update>.

=cut
