#!/usr/bin/env perl
# TKT-976, his message 7283 with a screenshot of the working panel: "Can you
# make the log inside a terminal like div? and only show last 100 and latest
# line show at first line, so they are reverse order to display inside the
# terminal like div. From new to old and auto refresh each 10 seconds".
#
# WHAT HE IS LOOKING AT. lib/Tira/Render.pm emits
# '<p class="bridge-note"></p><ol class="bridge-lines"></ol>' - an ordered
# list, which is the numbered 1..100 column in his screenshot - and
# bridge-panel.js appends entries in payload order, so the NEWEST line is at
# the bottom, a hundred rows down. On a panel that refreshes while he watches,
# the thing he is waiting for is the thing furthest from his eye.
#
# FOUR THINGS ASKED FOR, AND ONLY TWO ARE CHANGES. The container and the order
# are real. The hundred is ALREADY what the route gives and the panel already
# says so in its own note. The ten-second refresh is the other way round: the
# panel already polls every FIVE, so his number would SLOW it - asked as Q-132
# with a voice note rather than guessed at, and nothing here asserts an
# interval, because the cadence is his to decide and this test must not
# prejudge it.
#
# THE REVERSAL BELONGS IN THE PAGE, NOT IN THE ROUTE. /bridge is shared: the
# terminal and tira.policy.bridge.logs read the same engine call
# (Tira::enforcement_log), and t/541 exists because two readers of one log
# drift. So the payload order is asserted UNCHANGED here, and the panel is
# required to reverse what it was given at paint time. A fix that made the
# route answer newest-first would satisfy his eyes and quietly change what the
# board says everywhere else.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();

my $panel  = eval { Suite::view_source('bridge-panel.js') };
my $render = eval { Suite::engine_source() };

# non-empty is the whole claim: every check below would pass on an unreadable
# file's emptiness alone, and view_source DIES rather than returning empty for
# exactly that reason.
like( $panel  // '', qr/\S/, 'the bridge panel script is there to be read' );
like( $render // '', qr/\S/, 'the engine source is there to be read' );

# --- the container is a terminal, not a numbered list -----------------------
#
# The first thing he asked for, and the reason the screenshot shows 1..100 down
# the left-hand edge. Asserted against Render.pm, which emits the markup, so
# the claim is about what the page actually contains.

{
    my ($section) = ( $render // '' ) =~ /(board--bridge.{0,400})/s;
    like( $section // '', qr/bridge-lines/,
        'the bridge section was found, and is the one carrying the lines container - '
          . 'asserted by its content so a match on some other markup could not satisfy '
          . 'the checks below' );

    unlike( $section // '', qr/<ol\s+class="bridge-lines"/,
        'the lines are NOT an ordered list - a numbered 1..100 column is what he '
          . 'screenshotted and asked to be rid of' );

    like( $section // '', qr/<div\s+class="bridge-lines[^"]*"/,
        'they are a div, which is what a terminal-like block is built from' );
}

# --- and it is styled as a terminal ------------------------------------------
#
# A div alone would satisfy the check above and still look like a paragraph.
# The class has to reach the stylesheet, or "terminal like div" is only half
# done - and nothing else in the suite would notice.

{
    my $css = eval { Suite::view_source('dashboard.css') };
    # non-empty is the whole claim: the two checks below would pass on an
    # unreadable file's emptiness alone.
    like( $css // '', qr/\S/, 'the stylesheet is there to be read' );
    like( $css // '', qr/\.bridge-lines\b/,
        'the container has styling of its own, so it renders as a terminal block rather '
          . 'than as an unstyled div' );
    like( $css // '', qr/\.bridge-lines[^{]*\{[^}]*monospace/s,
        'and that styling is monospaced, which is the thing that makes it read as a '
          . 'terminal rather than as prose' );
}

# --- the newest line is painted first ----------------------------------------
#
# The whole card. The panel receives the payload oldest-first and must put the
# newest at the top of what it draws.

{
    # NOT /x here. Under /x the literal spaces in "\n  \};" are ignored, so the
    # pattern demanded a closing brace in column one, matched nothing, and the
    # three checks below failed for a reason that had nothing to do with the
    # code - an extraction that catches nothing reads exactly like a fix that
    # was never made.
    my ($paint) = ( $panel // '' ) =~ /(const\s+paintBridge\s*=.*?\n\s*\};)/s;
    like( $paint // '', qr/bridgeList/,
        'paintBridge was found, and is the one that fills the container - asserted by '
          . 'its content rather than by being non-empty' );

    like( $paint // '', qr/\bslice\(\)\.reverse\(\)|\breverse\(\)/,
        'it reverses the entries before drawing them, so the newest line is the first '
          . 'one he sees instead of the hundredth' );

    like( $paint // '', qr/slice\(\)\s*\.\s*reverse\(\)/,
        'and it reverses a COPY - reverse() mutates in place, so reversing the array '
          . 'the payload was parsed into would leave any later reader of it holding a '
          . 'list in an order nothing else on the page expects' );
}

# --- the payload order is untouched ------------------------------------------
#
# The regression that matters most, and the reason the reversal is in the page.
# /bridge is read by the terminal and by tira.policy.bridge.logs through the
# same engine call; a route that answered newest-first would change what the
# board says everywhere, to fix how one panel looks.

{
    my ($route) = ( $render // '' ) =~ /(sub\s+enforcement_log\s*\{\n.*?\n\})/s;
    $route //= '';

    # ESTABLISHED BY CONTENT BEFORE IT IS DENIED. An extraction that caught
    # nothing leaves '', and '' contains no "reverse" - so the denial below
    # would pass hardest exactly when this test had stopped reading the sub it
    # is about. t/147 refused this file for that, and it was right: the same
    # fault had already bitten this very file once, when a /x pattern ignored
    # the literal spaces in its paintBridge anchor and matched nothing.
    like( $route, qr/A police store is required/,
        'enforcement_log was found, and is the one that refuses without a store - so the '
          . 'denial below is about the real sub rather than about an empty string' );

    unlike( $route, qr/\breverse\b/,
        'the engine log reader does not reverse - the terminal and the page read the '
          . 'same call, and t/541 exists because two readers of one log drift' );
}

# --- the empty and failed-read states survive --------------------------------
#
# Three states, not two: TKT-949 separated "nothing found" from "could not be
# read", after he reported the panel as never working and it could not tell him
# which it was. A markup change is exactly the kind of edit that quietly takes
# that back.

{
    like( $panel // '', qr/Nothing on the bridge yet\. Police announces here when it runs\./,
        'a quiet bridge still says so in words' );
    like( $panel // '', qr/The bridge could not be read for this board/,
        'and a failed read still says THAT, which is a different claim - the distinction '
          . 'TKT-949 added after he reported the panel as never working' );
    like( $panel // '', qr/The last " \+ entries\.length \+ " thing\(s\) police said/,
        'and the count sentence is unchanged, so the hundred-line limit still describes '
          . 'itself and is still the route\'s to decide' );
}

# --- the cadence stays where he left it --------------------------------------
#
# Q-132, answered by him at 2026-09-06T21:10:02+0100: "Leave it at five seconds
# - keep it as live as it is now". His message had asked for ten; when told the
# panel already polls at five and that ten would SLOW it, he withdrew the
# number. So five is now a decision rather than an accident, and the exact
# value is asserted - a later edit to ten would be undoing something he chose.

{
    like( $panel // '', qr/setInterval\(\s*refreshBridge\s*,\s*5000\s*\)/,
        'the panel still polls every five seconds, which is what he chose in Q-132 when '
          . 'the ten he first asked for turned out to be slower than what he already had' );
}

done_testing();

__END__

=head1 NAME

583-a-log-read-from-the-wrong-end.t - the bridge panel is a terminal, newest line first

=head1 DESCRIPTION

TKT-976. The Bridge panel rendered the board's running log as a numbered
ordered list, oldest first, so the newest line - the one somebody watching a
live board is waiting for - sat at the bottom behind ninety-nine lines they had
already read.

This holds the fix: the container is a monospaced div rather than an C<< <ol> >>,
the panel reverses a COPY of the entries at paint time, and C<enforcement_log>
is left answering in its own order, because the terminal and
C<tira.policy.bridge.logs> read that same call and t/541 exists because two
readers of one log drift. The three display states TKT-949 separated are
asserted unchanged, and the poll interval is deliberately not asserted at all
while Q-132 is open.

=cut
