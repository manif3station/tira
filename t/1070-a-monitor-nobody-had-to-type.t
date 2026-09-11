#!/usr/bin/env perl
# TKT-1068. Michael, via TG msg #8172 (2026-09-11, verbatim): "now is time.
# by default to run d2 tira.dashboard these options is opt-in by default -o
# browser --no-session-expire --with-police --with-policy-bridge... So there
# are 2 things here and put 1 ticket cover these" - the second being that
# agents must know to run the dashboard as a watched monitor.
#
# This file covers the first: a bare `d2 tira.dashboard` (no --output given
# at all) now behaves as if -o browser, --no-session-expire, --with-police
# and --with-policy-bridge were all given. An explicit --output overrides the
# whole bundle (asking for toon/json/human/table is a deliberate one-shot
# read, not a request to serve). Each of the three extras has its own
# opt-out: --no-police, --no-policy-bridge, --with-session-expire.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite;
use Tira;
use Tira::CLI;

# --- the parser knows the three opt-out flags -------------------------------

my $cli = Suite::cli_source();

# non-empty is the whole claim: this only precedes reading real flags out of
# $cli below, so all it asserts is that the source was actually read.
like( $cli, qr/\S/, 'the command surface was walked to look for the flags' );

for my $flag (qw(no-police no-policy-bridge with-session-expire)) {
    like( $cli, qr/'\Q$flag\E/, "THE PARSER DECLARES --$flag, the opt-out for its own default" );
}

# --- driven through the real dispatcher, with every fork seam injected -----

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Defaulted', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'DFS', epic_prefix => 'DFE', ticket_prefix => 'DFT',
);

my ( $served, @police_started, @bridge_started, $never_expires );
my $run = sub {
    my (@extra) = @_;
    my $command = @extra && $extra[0] =~ /\Adashboard(?:\.(?:sow|epic|ticket))?\z/ ? shift @extra : 'dashboard';
    $served = 0; @police_started = (); @bridge_started = (); $never_expires = 0;
    no warnings 'once';
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        local $Tira::SESSION_NEVER_EXPIRES = 0;
        Tira::CLI->run(
            command               => $command,
            tira                  => $tira,
            argv                  => [@extra],
            browser_server        => sub { $served = 1; return 1 },
            police_starter        => sub { push @police_started, {@_}; return 5150 },
            police_stopper        => sub { return 1 },
            policy_bridge_starter => sub { push @bridge_started, {@_}; return 5151 },
            policy_bridge_stopper => sub { return 1 },
        );
        # Captured before local() unwinds on block exit.
        $never_expires = $Tira::SESSION_NEVER_EXPIRES;
    }
    return ( $out, $err );
};

# --- no flags at all: all four defaults apply -------------------------------

$run->();
ok( $served, 'a bare dashboard command serves in browser mode by default' );
is( scalar @police_started, 1, 'and police starts beside it by default' );
is( scalar @bridge_started, 1, 'and the policy bridge starts beside it by default' );
ok( $never_expires, 'and sessions do not expire by default' );

# --- an explicit --output overrides the whole bundle ------------------------

$run->( '-o', 'toon' );
ok( !$served, 'an explicit -o toon does not serve in browser mode' );
is( scalar @police_started, 0, 'and does not start police' );
is( scalar @bridge_started, 0, 'and does not start the policy bridge' );

# --- each opt-out disables only its own concern -----------------------------

$run->('--no-police');
ok( $served, '--no-police still serves in browser mode' );
is( scalar @police_started, 0, 'and police does not start' );
is( scalar @bridge_started, 1, 'but the policy bridge still starts - --no-police does not touch it' );

$run->('--no-policy-bridge');
is( scalar @police_started, 1, '--no-policy-bridge does not touch police' );
is( scalar @bridge_started, 0, 'and the policy bridge does not start' );

$run->('--with-session-expire');
ok( $served, '--with-session-expire still serves in browser mode' );
ok( !$never_expires, 'and sessions expire again' );

# --- the type-specific forms (.sow/.epic/.ticket) carry the same default ---
#
# The regex gating the default matches all four command shapes, not just
# bare 'dashboard' - a card filed with only that one name in mind would
# otherwise leave dashboard.sow/.epic/.ticket with the OLD toon-by-default
# behavior, three commands quietly out of step with the fourth.

for my $type (qw(sow epic ticket)) {
    $run->( "dashboard.$type" );
    ok( $served, "a bare dashboard.$type also serves in browser mode by default" );
    is( scalar @police_started, 1, "and police starts beside dashboard.$type by default" );
    is( scalar @bridge_started, 1, "and the policy bridge starts beside dashboard.$type by default" );

    $run->( "dashboard.$type", '-o', 'toon' );
    ok( !$served, "an explicit -o toon on dashboard.$type does not serve in browser mode" );
}

done_testing;

__END__

=head1 NAME

t/1070-a-monitor-nobody-had-to-type.t - a bare dashboard command defaults to
browser+police+policy-bridge+no-session-expire

=head1 DESCRIPTION

TKT-1068. C<d2 tira.dashboard> with no C<--output> given at all now behaves
as if C<-o browser --no-session-expire --with-police --with-policy-bridge>
were all typed, his own words on TG msg #8172. An explicit C<--output>
overrides the whole bundle - a one-shot toon/json/human/table read is a
deliberate choice, not a request to serve. C<--no-police>,
C<--no-policy-bridge>, and C<--with-session-expire> each opt out of exactly
one of the three extras without touching the others or the browser default
itself.

=cut
