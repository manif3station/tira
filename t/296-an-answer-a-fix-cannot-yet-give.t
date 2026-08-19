#!/usr/bin/env perl
# police_outstanding is a pure read of the violation ledger - it never runs an
# evaluation itself. The ledger only updates when the background watcher's own
# loop ticks, which defaults to 30 seconds. So fixing a violation and
# immediately asking tira.police.outstanding can get told it is still open,
# for up to 30 seconds, purely because the watcher has not ticked since the
# fix - not because the fix did not work. Measured live this session, twice
# within one hour: a fix that landed at 13:40:56 still read as outstanding "as
# of the pass at 13:40:33" at both a 2s and a 5s recheck, only clearing 36
# seconds after the fix. TKT-423.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp   = tempdir( CLEANUP => 1 );
my $store = File::Spec->catdir( $tmp, 'store' );
my $now   = '2026-08-19T09:00:00Z';

my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Fresh', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'FRS', epic_prefix => 'FRE', ticket_prefix => 'FRT',
);
$tira->policy_add( project => $root, rule => 'card-unassigned', action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Nobody on it' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );

# One pass records the violation as open in the ledger - the state a plain
# read answers from until the watcher ticks again.
$tira->police_pass( project => $root, store => $store, world => {} );
is( scalar @{ $tira->police_outstanding( store => $store ) }, 1,
    'the violation is recorded as open after one pass' );

# Fixed, but the ledger has not been told - the watcher has not ticked since.
$tira->assignment_set( project => $root, ref => $card->{ref}, people => ['claude'] );

my $run = sub {
    my (@argv) = @_;
    my $out = '';
    open my $capture, '>', \$out or die $!;
    local *STDOUT = $capture;
    local $ENV{TIRA_HOME} = $root;
    Tira::CLI->run( command => 'police.outstanding', tira => $tira,
        argv => [ '--store', $store, '-o', 'json', @argv ] );
    return $out;
};

like( $run->(), qr/card-unassigned/,
    'without --fresh, the fix is invisible until the watcher ticks - the stale answer this ticket is about' );
unlike( $run->('--fresh'), qr/card-unassigned/,
    'with --fresh, the same fix is visible immediately - no sleep, no wait for the next tick' );

# --fresh writes the pass it runs, so a plain read straight after also sees it -
# --fresh is a way to ask sooner, not a separate world the plain read cannot see.
unlike( $run->(), qr/card-unassigned/,
    'and the fresh pass it ran is not thrown away - a plain read straight after sees it too' );

done_testing;

__END__

=head1 NAME

296-an-answer-a-fix-cannot-yet-give.t - police.outstanding --fresh answers
without waiting for the watcher's next tick

=head1 DESCRIPTION

police.outstanding reads whatever the background watcher last wrote, which
can be up to 30 seconds stale relative to a fix just made. --fresh runs one
police pass inline before reading, so confirming a fix does not require
sleeping and re-asking - the loop this project already runs on every fix.

=cut
