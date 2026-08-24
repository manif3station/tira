#!/usr/bin/env perl
# TKT-494: "Add a UI to allow to select which column is new ticket entry
# point. It can be multiple entries." (Michael's own words). The engine and
# CLI already support more than one entry column (TKT-496, TKT-428) - this
# is the dashboard's own half: the Columns dialog's GET /columns now says
# which columns already carry the entry role, and POST /columns/apply now
# accepts the checked set and writes it back through column_roles_set, the
# same engine call tira.column.roles --role entry=X already makes.

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

my $tira = Tira->new( clock => sub { '2026-08-24T12:00:00Z' } );
$tira->project_new(
    name => 'ManyDoors', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'implement', 'done' ],
    sow_prefix => 'MDS', epic_prefix => 'MDE', ticket_prefix => 'MDT',
);
$tira->login_register( project => $root, id => 'claude', password => 'hunter2' );

# --- the columns provider says which columns are already entry points -----
my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
my $before = Cpanel::JSON::XS::decode_json( $providers{columns}->( { type => 'ticket' } ) );
ok( !( grep { $_->{entry} } @{$before} ), 'nothing is an entry column before any is declared' );

$tira->column_roles_set( project => $root, type => 'ticket', roles => { entry => ['backlog'] } );
my $after = Cpanel::JSON::XS::decode_json( $providers{columns}->( { type => 'ticket' } ) );
my %by_name = map { $_->{name} => $_ } @{$after};
ok( $by_name{backlog}{entry}, 'the declared entry column is marked entry: true' );
ok( !$by_name{planning}{entry}, 'and a column that is not one is marked entry: false, not omitted' );

# --- column_apply's provider writes the checked set back through the engine
my $applied = Cpanel::JSON::XS::decode_json( $providers{column_apply}->( {
    type    => 'ticket',
    columns => [ map { { name => $_ } } qw(backlog planning implement done discard) ],
    entry   => [ 'backlog', 'planning' ],
} ) );
is_deeply( $tira->column_roles( project => $root, type => 'ticket' )->{entry}, [ 'backlog', 'planning' ],
    'saving with two boxes checked declares both as entry columns' );

# Saving again with the set shrunk to one replaces it, the same full-replace
# semantics tira.column.roles --role entry=X already has, not an add-only merge.
$providers{column_apply}->( {
    type => 'ticket', columns => [ map { { name => $_ } } qw(backlog planning implement done discard) ],
    entry => ['planning'],
} );
is_deeply( $tira->column_roles( project => $root, type => 'ticket' )->{entry}, ['planning'],
    'unchecking one and saving again replaces the set, rather than only ever adding' );

# A save that says nothing about entry columns at all - the plain layout
# edits every other test already covers - leaves the entry role untouched.
$providers{column_apply}->( {
    type => 'ticket', columns => [ map { { name => $_ } } qw(backlog planning implement done discard) ],
} );
is_deeply( $tira->column_roles( project => $root, type => 'ticket' )->{entry}, ['planning'],
    'a save with no entry field leaves the declared entry columns exactly as they were' );

# --- the same thing, through the real HTTP route ---------------------------
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

    my $view = $http->( GET '/columns?type=ticket', Cookie => $cookie );
    is( $view->code, 200, 'GET /columns succeeds' );
    my $decoded = Cpanel::JSON::XS::decode_json( $view->content );
    my ($planning) = grep { $_->{name} eq 'planning' } @{$decoded};
    ok( $planning->{entry}, 'the real route reports the current entry column' );

    my $save = $http->( POST '/columns/apply', Cookie => $cookie,
        Content => Cpanel::JSON::XS->new->encode( {
            type => 'ticket', columns => [ map { { name => $_ } } qw(backlog planning implement done discard) ],
            entry => [ 'backlog', 'done' ],
        } ) );
    is( $save->code, 200, 'POST /columns/apply with an entry list succeeds' ) or diag( $save->content );
    is_deeply( $tira->column_roles( project => $root, type => 'ticket' )->{entry}, [ 'backlog', 'done' ],
        'and the real route writes the new set through' );
};

done_testing;

__END__

=head1 NAME

379-a-board-with-more-than-one-front-door.t - the Columns dialog can declare more than one entry column

=head1 DESCRIPTION

TKT-494 gave the Columns dialog a checkbox per column for "new cards can
start here", writing through to the same column_roles_set the CLI's
tira.column.roles --role entry=X already calls - full-replace semantics,
not additive, matching t/374's own coverage of the engine half (TKT-496).
Covers the columns provider surfacing which columns already carry the
entry role, column_apply's provider writing a submitted set through, a
save with no entry field leaving the existing set untouched, and the same
behaviour through the real HTTP routes.
