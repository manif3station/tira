#!/usr/bin/env perl
# The board is served from a file, so its workers can be told to read it again.
#
# Reported by the owner on 2026-08-15: "When installed new Tira in new version.
# Dashboard and police won't reload themselves." The police half shipped in
# 1.98. This is the other half.
#
# He sent me to Starman's documentation and he was right: HUP restarts workers
# gracefully while the master keeps the listening socket, so nothing has to exec
# and nothing has to rebind. I had this written down as impossible, reasoned
# from the failure we hit rather than from the tool.
#
# What stopped HUP working here is ours. serve() builds the application in this
# process and hands Plack::Runner a coderef, so the app is in memory before
# Starman forks and re-forked workers inherit the same code - the preloaded
# case, whatever the flag says.
#
# Proved before choosing: a two-worker Starman serving a .psgi that reads a
# version from a file answered "version one"; the file changed, the master was
# sent HUP, and it answered "version two" - same master, socket never closed.
#
# And the file already exists. dashboard.psgi has been in the skill root all
# along, building the whole application from TIRA_DASHBOARD_ROOT with the same
# providers the CLI uses, and nothing references it. So this is wiring rather
# than construction - and the file being unexercised is itself worth a test,
# which is most of what is below.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'board' );

$tira->project_new(
    name => 'Served', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SVS', epic_prefix => 'SVE', ticket_prefix => 'SVT',
);
$tira->create_record( project => $root, type => 'ticket', title => 'On the board' );

# --- the file that is served exists and builds an application ---------------------
#
# It has shipped unexercised: nothing in the suite or the commands referenced it
# before this test, so a change to the providers could have broken it silently.

# './' matters. do() with a bare relative name searches @INC rather than the
# current directory, so 'dashboard.psgi' silently finds nothing and the failure
# reads as the file being broken - which is exactly the wrong conclusion, and
# one I drew from a neighbouring mistake an hour before this was written.
my $psgi = './dashboard.psgi';
ok( -f $psgi, 'the board ships a psgi file to be served from' );

{
    local $ENV{TIRA_DASHBOARD_ROOT} = $root;
    local $ENV{TIRA_DASHBOARD_TYPE} = 'ticket';
    my $app = do $psgi;
    ok( ref $app eq 'CODE', 'and loading it yields an application' )
      or diag( $@ || $! || 'no reason given' );
}

# --- it refuses to be loaded without a board ----------------------------------------
#
# A served board with no root would answer every request about nothing, which is
# worse than not starting.

{
    local $ENV{TIRA_DASHBOARD_ROOT};
    delete $ENV{TIRA_DASHBOARD_ROOT};
    my $app = do $psgi;
    ok( !$app, 'without a board it does not load' );
    like( $@ // $!, qr/TIRA_DASHBOARD_ROOT/,
        'and says which setting it needed' );
}

# --- and a board nobody named is refused before any worker starts ---------------------
#
# The workers load the file themselves and read TIRA_DASHBOARD_ROOT from the
# environment, so serving without a board would start workers that die on load -
# in a child whose error stream nobody is reading, which is the worst place for
# a message to go. It is refused here instead, where somebody sees it.

{
    require Tira::DashboardWeb;
    my $refused = !eval { Tira::DashboardWeb->serve( host => '127.0.0.1', port => 15097 ); 1 };
    ok( $refused, 'serving without a board is refused' );

    # It says what is missing, not how a board is named. This asked for the
    # selector by name until TKT-232, which is the rule the whole arrangement
    # exists for: a reader who learns that a flag pointing at a board exists
    # goes looking for the board. Two of my own tests then wanted opposite
    # things and the suite is what noticed.
    like( $@, qr/Serving a board needs to know which one/,
        'and says what is missing' );
    unlike( $@, qr/--project|TIRA_HOME/,
        'without naming how a board is selected, which is not the reader\'s to know' );
}

# --- and the server is pointed at the file rather than at a closure -----------------
#
# The whole of the restart. A coderef built here is in memory before Starman
# forks, so workers inherit it and a HUP reloads nothing; a path is read by each
# worker, so a HUP reads the modules from disk again.

{
    require Tira::DashboardWeb;
    require Plack::Runner;
    require Tira::CLI;

    # Every provider, from the one place that builds them, rather than a
    # hand-written list. The first draft of this block listed thirteen by name,
    # build_psgi_app rightly refused the rest, and I read its complaint as
    # coming from dashboard.psgi and raised a card saying that file was broken.
    # It was not: it loads and returns a coderef. The lesson is in the shape of
    # this block now - ask the code what it needs rather than assert it.
    my $tira = Tira->new;
    my %providers = (
        render => sub {'<html></html>'},
        data => sub {'{}'},
        Tira::CLI::browser_providers( tira => $tira, project => $root ),
    );

    my %given;
    {
        no warnings 'redefine';
        local *Plack::Runner::run = sub { my $self = shift; $given{app} = shift; return 1 };
        local *Plack::Runner::parse_options = sub { my $self = shift; $given{options} = [@_]; return 1 };
        Tira::DashboardWeb->serve(
            project => $root, host => '127.0.0.1', port => 15098, %providers );
    }

    ok( defined $given{app}, 'the server is given something to serve' );
    ok( !ref $given{app},
        'and it is a path to load rather than an application already built' );
    like( $given{app} // '', qr/dashboard\.psgi\z/,
        'namely the psgi file that ships with the skill' );
}

done_testing;

__END__

=head1 NAME

203-a-board-served-from-a-file.t - the dashboard can be told to read its code again

=head1 DESCRIPTION

C<serve> built the application in the launching process and handed
C<Plack::Runner> a coderef, so Starman's workers inherited it and a C<HUP>
reloaded nothing - which is why a served board went on running old code after an
upgrade.

It is now served from C<dashboard.psgi>, which has shipped unexercised since it
was written and which builds the same application from C<TIRA_DASHBOARD_ROOT>
with the same providers. Workers load it, so a C<HUP> re-forks workers that read
the modules from disk while the master keeps the listening socket.

=cut
