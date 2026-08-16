#!/usr/bin/env perl
# Police watches the board with the code that is installed, not the code it
# started with.
#
# Reported by the owner on 2026-08-15: "When installed new Tira in new version.
# Dashboard and police won't reload themselves." Two halves, and this file is
# the police one, which is not a fault to find but a feature never built.
#
# The machinery has existed since the dashboard needed it. _restart_if_updated
# asks whether the code on disk differs from the code running - not whether a
# label in .env moved, because exec loads the same module again and disagrees
# with .env again, and four boards did that every sixty seconds for twenty
# hours. _restart_into passes the arguments and a clean environment. Nothing in
# the police loop ever called either.
#
# So a police left running through a release keeps the rulebook it started with:
# rules that shipped since are not evaluated, wording that was corrected is
# still printed, and a board can be watched by a version nobody is running any
# more. It says nothing about that, which is the part that matters - a watcher
# reading old rules looks exactly like a watcher reading new ones.
#
# Between rounds, never during a pass. Police writes the bridge and the
# enforcement ledger, and a pass cut in half would leave a violation counted and
# unsaid, or said and uncounted.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Watching', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WTS', epic_prefix => 'WTE', ticket_prefix => 'WTT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

# What the restart hands the new process, which is now an environment rather
# than an argument. TKT-250.
my @handover;

sub follow {
    my (%args) = @_;
    my @restarted;
    my $rounds = 0;
    {
        no warnings 'redefine';
        local *Tira::CLI::_version_on_disk = sub { $args{disk} } if exists $args{disk};
        local *Tira::CLI::_entrypoint_for = sub { File::Spec->catfile( $tmp, 'police' ) };
        Tira::CLI::_police_follow(
            $tira, { project => $root }, $store,
            {   rounds => $args{rounds} // 2,
                sleeper => sub { $rounds++ },
                restarter => sub { push @restarted, [@_]; push @handover, $ENV{TIRA_HOME}; return 1 },
            }
        );
    }
    return \@restarted;
}

# --- new code under a running police ---------------------------------------------

{
    my $restarted = follow( disk => '9.99' );
    is( scalar @{$restarted}, 1, 'police restarts when the code on disk is not the code running' );
    like( $restarted->[0][0], qr/police/, 'into the police entrypoint' );
    my @argv = @{ $restarted->[0] };
    is( scalar( grep { $_ eq '--project' } @argv ), 0,
        'with nothing on the command line naming the board, because there is no such flag' );
    ok( defined $handover[0] && $handover[0] =~ /\S/,
        'carrying the board it was watching in the environment, so it does not have to rediscover one' );
}

# --- and not otherwise ------------------------------------------------------------
#
# A restart into the code already running is the loop that cost four boards
# twenty hours, and it is why the question is what the code is rather than what
# the label says.

is_deeply( follow( disk => $Tira::VERSION ), [],
    'and does not restart into the code it is already running' );

is_deeply( follow(), [],
    'nor when the version on disk cannot be read at all' );

# --- a single pass has nothing to carry on into --------------------------------------

is_deeply( follow( disk => '9.99', rounds => 1, once => 1 ), [],
    'a single pass does not restart, because there is nothing to carry on into' )
  if 0;    # --once is handled by the caller, not the loop; kept as a note

done_testing;

__END__

=head1 NAME

198-police-that-runs-the-code-that-is-installed.t - police restarts into new code

=head1 DESCRIPTION

The restart machinery existed for the dashboard and nothing in the police loop
called it, so a police left running through a release kept the rulebook it
started with - evaluating rules that had been superseded and printing wording
that had been corrected, while looking exactly like a police reading the current
ones.

It now restarts between rounds when the code on disk differs from the code
running, never during a pass, and never into the version it is already running.

=cut
