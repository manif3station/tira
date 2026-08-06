#!/usr/bin/env perl

use strict;
use warnings;

use FindBin ();

BEGIN {
    $FindBin::Bin =~ /\A([^\x00-\x1f\x7f]+)\z/ or die "Unsafe Tira skill root\n";
    unshift @INC, "$1/lib";
}

use Tira;
use Tira::DashboardWeb;

my $project = $ENV{TIRA_DASHBOARD_ROOT} // die "TIRA_DASHBOARD_ROOT is required\n";
my $type = $ENV{TIRA_DASHBOARD_TYPE};
my $with_title = ( $ENV{TIRA_DASHBOARD_TITLE} // '' ) eq '1';
my $tira = Tira->new;

Tira::DashboardWeb->build_psgi_app(
    render => sub {
        my %args = (
            project => $project, summary => 1, include_mtime => 1,
            with_title => $with_title,
        );
        $args{type} = $type if defined $type && length $type;
        return $tira->format_output(
            $tira->dashboard(%args), output => 'table', live => 1,
            with_title => $with_title,
        );
    },
    data => sub {
        my %args = ( project => $project, summary => 0 );
        $args{type} = $type if defined $type && length $type;
        return $tira->format_output( $tira->dashboard(%args), output => 'json' );
    },
);

__END__

=head1 NAME

dashboard.psgi - Live Tira Kanban PSGI application

=head1 DESCRIPTION

Creates the Dancer2 dashboard application for standard PSGI runners. The CLI
sets its validated board selection; each request reads current filesystem state
and emits a fresh self-contained HTML dashboard.

=cut
