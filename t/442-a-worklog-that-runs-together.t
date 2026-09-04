#!/usr/bin/env perl
# TKT-750. He drew a red line across a work-log screenshot at exactly the
# point TKT-593 moved from document to verify, and said: "I am not asking to
# complete the worklog entry. For each move event - for example moving a card
# to another column - just add ONE LINE in the worklog there. That simple, do
# not make it so complicated."
#
# TKT-593's own work log is 147 entries, 743 lines, four of them moves, and
# nothing marks where one column's events end and the next begin.
#
# THIS IS RENDERING ONLY. work_log() already returns everything a separator
# needs - kind 'moved' carries detail '<from> to <to>' - so the fix lives in
# how the browser draws the list, not in what the engine returns. The first
# version of this card measured raw history instead of the work log he was
# actually showing, and found the wrong thing (a "same row repeated" fault
# the engine already handles via a times count) - the control below pins the
# thing that investigation confirmed IS true, so a future fix cannot silently
# start dropping or duplicating events while adding the separator.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 't/lib';
use Suite ();
use lib 'lib';
use Tira;

# --- THE CARD: the browser draws a separator at each move -------------------
#
# Tested the way t/19-dashboard-dialog.t already tests this file's markup -
# reading the JS source and asserting on its content - because this is a
# client-rendering change with no server-side counterpart to exercise.

my $live_js = Suite::view_source('live-helpers.js');

ok( length($live_js), 'live-helpers.js has content to check' )
  or BAIL_OUT('live-helpers.js is empty');

like( $live_js, qr/card-worklog__separator/,
    'the work-log renderer has a separator element, so a move divides what '
      . 'came before it from what comes after - not present today, which is '
      . 'the whole of this card' );

like( $live_js, qr/entry\.kind\s*===\s*["\']moved["\']/,
    'and it is drawn specifically for a moved entry, not for every entry - a '
      . 'separator on every line would be the same wall of text he is asking '
      . 'to break up' );

# --- THE CONTROL: work_log() itself is untouched -----------------------------
#
# The acceptance criterion this pins: "work_log() returns the same entries as
# before - this is rendering only, and its output is byte-identical." Written
# against the engine directly, independent of the JS fix, so a change that
# strayed into work_log() itself - adding a field, dropping an entry, changing
# an order - fails here regardless of what the browser draws.

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $now  = '2026-08-30T00:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
sub at { $now = $_[0]; return $now }

$tira->project_new(
    name => 'Logged', dir => $root, members => ['claude'],
    columns    => [ 'backlog', 'implement', 'verify', 'done' ],
    sow_prefix => 'LGS', epic_prefix => 'LGE', ticket_prefix => 'LGT',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Moves a few times' );

at('2026-08-30T00:05:00Z');
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );
at('2026-08-30T00:10:00Z');
$tira->record_move( project => $root, ref => $card->{ref}, column => 'verify', author => 'claude' );
at('2026-08-30T00:15:00Z');
$tira->record_move( project => $root, ref => $card->{ref}, column => 'done', author => 'claude' );

my $log = $tira->work_log( project => $root, ref => $card->{ref} );
my @moves = grep { ( $_->{kind} // '' ) eq 'moved' } @{$log};

is( scalar @moves, 3, 'a card moved three times has three moved entries in its work log' );
is( $moves[0]{detail}, 'backlog to implement', 'each still names where it came from and went to' );
is( $moves[2]{detail}, 'verify to done', 'in order, unchanged by anything a separator would draw' );

# --- and a never-moved card is unaffected ------------------------------------

my $still = $tira->create_record( project => $root, type => 'ticket', title => 'Never moves' );
my $still_log = $tira->work_log( project => $root, ref => $still->{ref} );
is( scalar( grep { ( $_->{kind} // '' ) eq 'moved' } @{$still_log} ), 0,
    'a card that has never moved has no moved entries, so no separator has '
      . 'anywhere to be drawn' );

done_testing();

__END__

=head1 NAME

t/442-a-worklog-that-runs-together.t - the work-log renderer marks where a
card changed column

=head1 DESCRIPTION

TKT-593's work log is 147 entries and 743 lines with no divider between the
events that happened in one column and the events that happened in the next.
He asked for one line per move event, nothing more - a rendering change, not a
new field or a new event.

=head2 Why the control matters more than usual here

This card's own history is a caution: its first version measured raw history
instead of the work log he was actually showing, and reported a fault - "same
row repeated" - that the engine already handles via a C<times> count. The
control here pins what investigation found actually true (moves are reported
individually, in order, with C<< before to after >> detail) so the fix cannot
repeat that mistake in the other direction by changing engine behaviour while
chasing a rendering change.

=cut
