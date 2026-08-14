#!/usr/bin/env perl
# A replayed backlog cannot be read as a storm of new violations.
#
# zen-framework asked for this, and the evidence they offered was their own
# false report. When the bridge's buffering was worked around, it replayed its
# whole outstanding backlog at once: old lines about cards that had since moved,
# arriving together. They read that pile as one rule firing across every
# discarded card and filed TKT-136 on it. 1.51 refuted it - entering a column is
# an exact match and discard is already excluded by name - and 1.51's settlement
# lines help, but they are the other half of this rather than a substitute:
#
#   A settlement says a violation stopped being true. It does not say that the
#   twelve lines you are reading right now are history rather than news.
#
# 1.50's own changelog anticipated it: fixing the buffering made this matter
# more rather than less, because now the backlogs get read. An agent restarting
# a bridge meets its worst moment first.
#
# Their first choice, and the cheapest: one line before the replay saying how
# many are outstanding and the span they were raised over. Their second - a mark
# on every replayed line - was rejected here because it changes the shape of
# every line an agent parses, for a distinction that only matters at the
# boundary.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-14T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $store = File::Spec->catdir( $tmp, 'police' );

sub say_it {
    my ( $id, $ref ) = @_;
    $tira->bridge_write( store => $store, violations => [ {
        id => $id, rule => 'card-stalled', ref => $ref,
        detail => 'every checklist item is done but the card is still in implement',
        action => 'bridge-reminder', tone => 'note', seen => 1,
    } ] );
    return;
}

# --- nothing outstanding says nothing -------------------------------------------------
#
# Silence is still the signal. A header announcing an empty backlog would be the
# all-clear announcement the whole channel is built to avoid.

is_deeply( $tira->bridge_backlog( store => $store, lines => 50 ), [],
    'a bridge with nothing outstanding replays nothing' );

# --- a pile of history ------------------------------------------------------------------

say_it( 'VIO-0001', 'TKT-001' );
$now = '2026-08-14T09:30:00Z';
say_it( 'VIO-0002', 'TKT-002' );
$now = '2026-08-14T10:15:00Z';
say_it( 'VIO-0003', 'TKT-003' );

$now = '2026-08-14T11:00:00Z';
my $replay = $tira->bridge_backlog( store => $store, lines => 50 );

# --- the line that says what this is ------------------------------------------------------

my ($header) = @{$replay};
like( $header, qr/replay/i, 'the replay says it is a replay before it says anything else' );
like( $header, qr/\b3\b/, 'and how many lines are outstanding' );
like( $header, qr/09:00/, 'and when the oldest was raised' );
like( $header, qr/10:15/, 'and when the newest was' );

# --- and the lines themselves are untouched ------------------------------------------------
#
# Their second choice was marking every replayed line, and it was not taken: an
# agent parses these, and changing the shape of every line for a distinction
# that only matters at the boundary costs more than it settles.

is( scalar @{$replay}, 4, 'the header, and then the three lines' );
like( $replay->[1], qr/VIO-0001/, 'the oldest line is unchanged' );
like( $replay->[3], qr/VIO-0003/, 'and so is the newest' );
unlike( $replay->[1], qr/replay/i, 'no line carries a mark of its own' );

# --- one violation is still a pile worth naming ---------------------------------------------
#
# The ambiguity is not about volume. One old line read as news sends an agent
# after work that is already done, which is the same fault at a smaller size.

my $single = File::Spec->catdir( $tmp, 'police-single' );
$tira->bridge_write( store => $single, violations => [ {
    id => 'VIO-0009', rule => 'card-stalled', ref => 'TKT-009', detail => 'still in implement',
    action => 'bridge-reminder', tone => 'note', seen => 1,
} ] );
my $one = $tira->bridge_backlog( store => $single, lines => 50 );
like( $one->[0], qr/replay/i, 'a single outstanding line is still introduced as history' );
is( scalar @{$one}, 2, 'with the line after it' );

# --- and what an agent asked for is still what it gets ----------------------------------------
#
# The backlog is filtered to the agent reading it. A header counting lines that
# agent will not see would be a number about somebody else's work.

$now = '2026-08-14T11:30:00Z';
$tira->bridge_write( store => $store, violations => [ {
    id => 'VIO-0004', rule => 'card-stalled', ref => 'TKT-004', detail => 'still in implement',
    action => 'bridge-reminder', tone => 'note', seen => 1, assignee => 'ada',
} ] );
my $hers = $tira->bridge_backlog( store => $store, lines => 50, agent => 'ada' );
like( $hers->[0], qr/\b4\b/, 'an agent is told how many lines it is about to read' );
is( scalar @{$hers}, 5, 'and reads them' );

done_testing;

__END__

=head1 NAME

161-history-is-not-news.t - a replayed backlog cannot be read as a storm

=head1 DESCRIPTION

A bridge that starts prints what is outstanding and then live traffic, with
nothing separating them, so a pile of old lines about cards that have moved on
reads as a storm of new violations. The reporter had already filed a false
report from exactly that, and offered it as the evidence.

The replay is introduced by one line saying how many are outstanding and the
span they were raised over. The lines themselves are untouched: marking each one
would change the shape of every line an agent parses for a distinction that only
matters at the boundary. A bridge with nothing outstanding still says nothing.

=cut
