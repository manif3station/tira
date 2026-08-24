#!/usr/bin/env perl
# TKT-357. "ZEPG-6 has a checklist of ELEVEN ITEMS, ALL DONE. checklist-idle
# fired on it at 3h and escalated to CRITICAL. There is nothing left to tick
# - not 'nothing worth ticking', literally nothing." The rule is right to
# fire - TKT-358 already confirmed both halves: it fires on a complete
# checklist, and moving the card settles it. What is wrong is the sentence:
# "no checklist movement since TIMESTAMP" names the one action that cannot
# be taken (there is no unticked item) and never names the one that works
# (moving the card on).

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-24T10:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Ticked', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'TKS', epic_prefix => 'TKE', ticket_prefix => 'TKT',
);
my $store = File::Spec->catdir( $tmp, 'police-store' );

$tira->policy_add( project => $root, rule => 'checklist-idle',
    column => 'implement', age => '10m', action => 'bridge-reminder' );

sub idle_findings {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq 'checklist-idle' } @{ $pass->{violations} } ];
}

# --- a complete checklist is told to move, not that nothing has moved ------
my $done_card = $tira->create_record( project => $root, type => 'ticket', title => 'All eleven ticked' );
$tira->record_move( author => 'claude', project => $root, ref => $done_card->{ref}, column => 'implement' );
$tira->checklist_add( author => 'claude', project => $root, ref => $done_card->{ref}, item => 'first', status => 'done' );
$tira->checklist_add( author => 'claude', project => $root, ref => $done_card->{ref}, item => 'second', status => 'Done' );

$now = '2026-08-24T10:20:00Z';
my @found = @{ idle_findings() };
is( scalar @found, 1, 'the rule still fires on a complete checklist, exactly as TKT-358 confirmed' );
like( $found[0]{detail}, qr/move the card/i, 'and the message says to move the card' );
unlike( $found[0]{detail}, qr/no checklist movement/, 'not that the checklist has not moved - there is nothing left to move' );

# --- an incomplete checklist keeps the existing message ---------------------
$now = '2026-08-24T10:00:00Z';
my $open_card = $tira->create_record( project => $root, type => 'ticket', title => 'One still open' );
$tira->record_move( author => 'claude', project => $root, ref => $open_card->{ref}, column => 'implement' );
$tira->checklist_add( author => 'claude', project => $root, ref => $open_card->{ref}, item => 'finished', status => 'done' );
$tira->checklist_add( author => 'claude', project => $root, ref => $open_card->{ref}, item => 'not yet', status => 'pending' );

$now = '2026-08-24T10:20:00Z';
my @open_found = grep { $_->{ref} eq $open_card->{ref} } @{ idle_findings() };
is( scalar @open_found, 1, 'a card with an unticked item still fires' );
like( $open_found[0]{detail}, qr/no checklist movement/, 'keeping the message it has now' );
unlike( $open_found[0]{detail}, qr/move the card/i, 'and not the complete-checklist wording' );

done_testing;

__END__

=head1 NAME

384-a-checklist-with-nothing-left-to-tick.t - checklist-idle's message matches what the reader can actually do

=head1 DESCRIPTION

TKT-357: checklist-idle's "no checklist movement since TIMESTAMP" message
was true and useless on a checklist that is 100% complete - it names the
one action that cannot be taken and never the one that works. The rule's
own behaviour is unchanged (TKT-358 already confirmed it fires correctly
and settles on the next move); only the message now distinguishes a
complete checklist ("move the card") from one with unticked items
(unchanged wording), reusing the same case-insensitive all-done check
checklist-unmoved already has (TKT-434).
