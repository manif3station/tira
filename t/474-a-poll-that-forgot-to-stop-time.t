#!/usr/bin/env perl
# TKT-807. lib/Tira/DashboardWeb.pm's %POLLED set exempted only '/data' from
# extending session expiry - "reading a session through it must not push the
# expiry out, or a tab left open overnight would keep itself signed in
# forever." But lib/Tira/views/tasklist-editor.js polls GET /tasklist every
# 1 second and GET /tasklist/sessions every 5 seconds, forever, whenever the
# Task List section is rendered - neither route was in %POLLED, so every one
# of those polls extended the session's expiry on every call. A dashboard
# tab left open with the Task List section visible never expired its
# session, defeating the mechanism %POLLED exists to provide. Found live
# during TKT-797's own verify pass.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Request::Common qw(GET POST);
use Plack::Test;
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'polled' );
my $now  = '2026-09-01T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
$tira->project_new(
    name => 'Polled', dir => $root, members => ['michael'],
    columns => ['Backlog, Doing'],
    sow_prefix => 'PLS', epic_prefix => 'PLE', ticket_prefix => 'PLT',
);
$tira->login_register( project => $root, id => 'michael', password => 'hunter2' );

my $app = Tira::DashboardWeb->build_psgi_app(
    Tira::CLI::browser_providers( tira => $tira, project => $root ),
    render => sub { return '<!doctype html><p>BOARD-SENTINEL</p>' },
    data   => sub { return '{"ticket":{"backlog":[]}}' },
);

test_psgi $app, sub {
    my ($http) = @_;

    my $login = $http->( POST '/login', Content => '{"id":"michael","password":"hunter2"}' );
    my ($token) = ( $login->header('Set-Cookie') // '' ) =~ /tira_session=([^;]+)/;

    for my $path (qw(/tasklist /tasklist/sessions)) {
        $now = '2026-09-01T09:09:00Z';
        isnt( $http->( GET $path, Cookie => "tira_session=$token" )->code, 401,
            "$path answers while the session is alive" );

        # tasklist-editor.js polls every 1s/5s, far more often than /data's
        # own periodic poll - simulated here as many polls across the
        # window, none of them a real user action.
        for ( 1 .. 5 ) {
            $http->( GET $path, Cookie => "tira_session=$token" );
        }

        $now = '2026-09-01T09:10:01Z';
        is( $http->( GET $path, Cookie => "tira_session=$token" )->code, 401,
            "but polling $path never extended it, so it ends ten minutes after the last real action - the fix" );

        # Fresh session for the next path in the loop.
        $now = '2026-09-01T09:00:00Z';
        my $again = $http->( POST '/login', Content => '{"id":"michael","password":"hunter2"}' );
        ($token) = ( $again->header('Set-Cookie') // '' ) =~ /tira_session=([^;]+)/;
    }

    done_testing;
};

__END__

=head1 NAME

t/474-a-poll-that-forgot-to-stop-time.t - automatic tasklist polling
never extends a session's expiry

=head1 DESCRIPTION

C<%POLLED> in C<lib/Tira/DashboardWeb.pm> exempted only C</data> from
extending session expiry. C<lib/Tira/views/tasklist-editor.js> polls
C<GET /tasklist> every second and C<GET /tasklist/sessions> every five,
forever, whenever the Task List section is rendered - neither route was
exempt, so every poll extended the session on every call. A dashboard
tab left open with that section visible never actually expired its
session, defeating the mechanism C<%POLLED> exists to provide.

Fixed by adding both routes to C<%POLLED>, exercised here the same way
C<t/77-login-gate.t> already proves it for C</data>. TKT-807.

=cut

