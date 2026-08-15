#!/usr/bin/env perl
# The application the workers load, loaded as they load it.
#
# dashboard.psgi is the file each Starman worker reads for itself. Nothing in
# the suite loaded it until 2.00 moved the application into the workers, and
# what the suite did check - that serve() hands the runner a path rather than a
# built app - is true of a psgi that cannot build anything at all.
#
# It went out that way. The workers built a Tira with no path resolver, so a
# board referred to by anything other than its path could not be found by the
# one process that had to find it, and every request died in a child whose
# errors reach a log nobody is tailing while the port sat listening.
#
# So the file is loaded here, the way a worker loads it, and asked for what a
# worker needs: an application, from the environment alone.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'served' );
Tira->new( clock => sub {'2026-08-15T20:00:00Z'} )->project_new(
    name => 'Served', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
);

# --- what a worker gets ------------------------------------------------------
{
    local $ENV{TIRA_DASHBOARD_ROOT} = $root;
    local $ENV{TIRA_DASHBOARD_TYPE} = '';
    local $ENV{TIRA_DASHBOARD_TITLE} = '0';

    my $app = do './dashboard.psgi';
    my $failed = $@ || $!;

    ok( !$@, 'the application a worker loads builds from the environment alone' )
      or diag $failed;
    is( ref $app, 'CODE', 'and it is something a server can run' );
}

# --- and when it is told nothing ---------------------------------------------
#
# A worker with no board must refuse loudly at load, not answer requests with
# something empty. The refusal is what a supervisor sees.
{
    local %ENV = %ENV;
    delete $ENV{TIRA_DASHBOARD_ROOT};

    my $app = do './dashboard.psgi';
    ok( !defined $app || ref $app ne 'CODE',
        'a worker told nothing does not quietly become a working server' );
    # non-empty is the whole claim: what matters is that a worker with no board
    # refuses out loud, not the words it chooses.
    like( $@ // '', qr/\S/, 'and says so where a supervisor reads it' );
}

# --- and when it is told something it cannot open ----------------------------
#
# This is the shape that shipped. The worker was handed a reference it had no
# way to resolve, built an application anyway, and answered every request with
# a failure - once per request, in a log. A worker that cannot serve the board
# it was given must say so at load, where whatever started it is still looking.
{
    local $ENV{TIRA_DASHBOARD_ROOT} = 'not-a-board-anybody-can-open';
    local $ENV{TIRA_DASHBOARD_TYPE} = '';
    local $ENV{TIRA_DASHBOARD_TITLE} = '0';

    my $app = do './dashboard.psgi';
    my $said = $@;

    ok( !defined $app || ref $app ne 'CODE',
        'a worker handed a board it cannot open does not become a server that fails per request' );
    # non-empty is the whole claim: the refusal has to reach whoever started the
    # worker, and which words it uses is not what this is about.
    like( $said // '', qr/\S/, 'it refuses at load, where whatever started it is still watching' );
}

done_testing;

__END__

=head1 NAME

212-the-application-a-worker-loads.t - loaded the way a worker loads it

=head1 DESCRIPTION

C<dashboard.psgi> is read by each Starman worker. The suite checked that
C<serve()> hands the runner a path to it, which is true of a psgi that cannot
build anything - and one that could not shipped.

Loaded here from the environment alone, as a worker does.

=cut
