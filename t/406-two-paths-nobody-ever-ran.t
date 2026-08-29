#!/usr/bin/env perl

# Two paths in Tira::CLI that no test had ever entered, found by reading the
# Devel::Cover DATABASE rather than its text report - which had been reporting
# lib/Tira/CLI.pm at 99.8% for days without ever naming a line, and which every
# grep-based check of mine called clean. The database names them in seconds:
#
#   _parent_of_pid, the fall-through when a status file exists but carries no
#   PPid: line at all. The found-it path was covered; the did-not-find-it path
#   ran off the end of the loop and nothing had ever gone that way.
#
#   The police loop's notice that it has told a stale dashboard to reload.
#   Untested because reaching it for real means signalling a real process, so
#   the decision is stubbed here and only the reporting is exercised.
#
# Both are small, and both blocked every push while the gate asked for 100%.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use Tira;
use Tira::CLI;
# Tira::CLI::Serve holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Serve;

my $tmp = tempdir( CLEANUP => 1 );

# --- a status file with no PPid: line ---------------------------------------
#
# /proc is the only source read here, and it is injectable, so this needs no
# real process and no platform that has /proc at all. What it stands in for is
# a kernel, container runtime or emulation whose status file is shaped
# differently from the one this parser expects - the reason the function
# returns undef rather than dying is precisely that it cannot assume.

my $proc = File::Spec->catdir( $tmp, 'proc' );
mkdir $proc or die $!;

my $silent = File::Spec->catdir( $proc, '4242' );
mkdir $silent or die $!;
open my $status, '>', File::Spec->catfile( $silent, 'status' ) or die $!;
print {$status} "Name:\tsomething\nState:\tS (sleeping)\nTgid:\t4242\n";
close $status;

is( Tira::CLI::_parent_of_pid( 4242, proc => $proc ), undef,
    'a status file with no PPid line reads as undef rather than dying or guessing' );

# The neighbouring case, so the two are asserted together rather than one being
# covered by accident somewhere else: a status file that does name a parent.
my $ordinary = File::Spec->catdir( $proc, '4243' );
mkdir $ordinary or die $!;
open my $ok, '>', File::Spec->catfile( $ordinary, 'status' ) or die $!;
print {$ok} "Name:\tsomething\nPPid:\t17\nState:\tS (sleeping)\n";
close $ok;

is( Tira::CLI::_parent_of_pid( 4243, proc => $proc ), 17,
    'and one that does name a parent still reads it' );

is( Tira::CLI::_parent_of_pid( 999999, proc => $proc ), undef,
    'a pid with no status file at all is undef too, by the same safe direction' );

# --- police says so when it reloads the board -------------------------------
#
# The decision is _dashboard_hup_if_stale's and is tested on its own in
# t/403-a-board-nobody-restarted.t, including that it signals once per release
# rather than once per pass. What was never tested is that police SAYS it did:
# a reload nobody is told about is indistinguishable from a board quietly
# serving stale code, which is the fault TKT-565 exists to prevent.
#
# Stubbed rather than driven for real, because the real path signals a live
# process by pid and a test that does that either kills itself or depends on
# some other process being there to receive it.
#
# Driven with --rounds rather than --once, and that is the whole reason this
# statement had never been executed: --once returns from the police branch
# BEFORE _police_follow is entered at all, and the reload notice lives inside
# that loop. Every existing police test uses --once, so no amount of adding
# more of them could ever have reached this line.

my $board = File::Spec->catdir( $tmp, 'board' );
mkdir $board or die $!;

my $tira = Tira->new;
$tira->project_new(
    name          => 'Noticing',
    dir           => $board,
    members       => 'ada',
    columns       => 'backlog, in-progress, done',
    sow_prefix    => 'SOW',
    epic_prefix   => 'EPC',
    ticket_prefix => 'TKT',
    author        => 'ada',
);

# Police returns before its loop on a project with an empty rulebook - it says
# so and stops, which is deliberate (silence from an unconfigured board is not
# compliance). So one declared rule is the price of entry to the loop at all.
$tira->policy_add(
    project => $board,
    rule    => 'card-full-details',
    enter   => 'in-progress',
    action  => 'log-only',
);

my $store = File::Spec->catdir( $tmp, 'police-store' );

my $err = '';
{
    open my $se, '>', \$err or die $!;
    no warnings 'redefine';
    local *Tira::CLI::Serve::_dashboard_hup_if_stale = sub {
        return { hupped => 1, pid => 4242, version => '9.99' };
    };
    local *STDERR = $se;
    local $ENV{TIRA_HOME} = $board;
    eval {
        Tira::CLI->run(
            command => 'police',
            tira    => $tira,
            argv    => [ '--rounds', '1', '--interval', '0', '--store', $store ],
        );
    };
}

like( $err, qr/police: told the dashboard \(pid 4242\) to reload into 9\.99/,
    'police says which board it reloaded and into what, rather than doing it silently' );

# And the other side of the same statement: no notice when nothing was stale,
# so the line stays worth reading. A message on every pass is one nobody reads,
# which is the same argument the move-in reminder is built on (TSK-168).

my $quiet = '';
{
    open my $se, '>', \$quiet or die $!;
    no warnings 'redefine';
    local *Tira::CLI::Serve::_dashboard_hup_if_stale = sub { return { hupped => 0 } };
    local *STDERR = $se;
    local $ENV{TIRA_HOME} = $board;
    eval {
        Tira::CLI->run(
            command => 'police',
            tira    => $tira,
            argv    => [ '--rounds', '1', '--interval', '0', '--store', $store ],
        );
    };
}

# Established before it is denied. police still speaks on this pass - it has an
# upgrade notice to give - so an empty $quiet would mean the run broke, not that
# the notice was correctly withheld, and the denial below would pass on the
# wreckage. t/147 exists to catch exactly that, and caught this.
isnt( $quiet, '', 'police still said something on that pass, so the denial below is about a real one' );

unlike( $quiet, qr/told the dashboard/,
    'and says nothing when the board was already serving the installed version' );

done_testing();

__END__

=head1 NAME

t/406-two-paths-nobody-ever-ran.t - the two paths in Tira::CLI that no
test had entered

=head1 DESCRIPTION

C<lib/Tira/CLI.pm> sat at 99.8% statement coverage and blocked every push,
while the gate would say only the percentage. Five attempts to find the missing
line through C<cover -report text> failed; reading the Devel::Cover database
named all three on the first call.

Two are C<_parent_of_pid>'s fall-through, where a status file exists but
carries no C<PPid:> line - the found-it path was covered and nothing had ever
run off the end of the loop. The third is the police loop's notice that it has
told a stale dashboard to reload, and that one was not merely untested but
unreachable by the tests that exist: C<--once> returns from the police branch
before C<_police_follow> is entered, and every police test in the suite uses
C<--once>. It needs C<--rounds>.

The reload decision itself is covered by
C<t/403-a-board-nobody-restarted.t>; here it is stubbed, because the real path
signals a live process by pid. What these assertions add is that police B<says>
it reloaded - a reload nobody is told about is indistinguishable from a board
quietly serving stale code, which is the fault TKT-565 exists to prevent - and
that it stays quiet when nothing was stale.

=cut
