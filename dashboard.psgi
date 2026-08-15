#!/usr/bin/env perl

use strict;
use warnings;

use FindBin ();

BEGIN {
    $FindBin::Bin =~ /\A([^\x00-\x1f\x7f]+)\z/ or die "Unsafe Tira skill root\n";
    unshift @INC, "$1/lib";
}

use Tira;
use Tira::CLI;
use Tira::DashboardWeb;

my $project = $ENV{TIRA_DASHBOARD_ROOT} // die "TIRA_DASHBOARD_ROOT is required\n";

# Opened here, at load, or this worker does not start.
#
# A worker that cannot reach its board used to become a server anyway and fail
# once per request, in a child whose errors reach a log nobody is tailing, while
# the port sat listening and the board looked up. That is how 2.00 went out and
# stayed out until somebody opened a browser.
#
# Whatever started this is still watching at load and has nowhere to look
# afterwards, so the failure belongs here.
my $type = $ENV{TIRA_DASHBOARD_TYPE};
my $with_title = ( $ENV{TIRA_DASHBOARD_TITLE} // '' ) eq '1';
# With the same resolver the CLI builds, so a worker is not the one process on
# the machine that cannot say which board it is serving.
#
# The board is resolved before these workers start and TIRA_DASHBOARD_ROOT
# carries a path, so this is a second line rather than the first. It exists
# because the first line failing here is invisible: a worker's complaint reaches
# a log nobody is tailing, once per request, while the port sits listening and
# the board looks up. That is exactly how this went out - the application moved
# into the workers, the resolver did not come with it, and every request died
# with "Cannot resolve project path" against a board whose reference was never a
# path in the first place.
my $tira = Tira->new( path_resolver => Tira::CLI::_dd_path_resolver() );

$project = eval { $tira->discover_project( project => $project ) }
  or die "This worker cannot open the board it was given\n";

Tira::DashboardWeb->build_psgi_app(
    render => sub {
        my %args = (
            project => $project, summary => 1, include_mtime => 1,
            with_title => $with_title,
        );
        $args{type} = $type if defined $type && length $type;
        return $tira->format_output(
            $tira->dashboard(%args), output => 'table', live => 1,
            with_title => $with_title, project => $project,
        );
    },
    data => sub {
        my %args = ( project => $project, summary => 1, with_title => $with_title, include_mtime => 1 );
        $args{type} = $type if defined $type && length $type;
        return $tira->format_output( $tira->dashboard(%args), output => 'json' );
    },
    Tira::CLI::browser_providers( tira => $tira, project => $project ),
);

__END__

=head1 NAME

dashboard.psgi - Live Tira Kanban PSGI application

=head1 DESCRIPTION

Creates the Dancer2 dashboard application for standard PSGI runners. The CLI
sets its validated board selection; each request reads current filesystem state
and emits a fresh self-contained HTML dashboard.

=cut
