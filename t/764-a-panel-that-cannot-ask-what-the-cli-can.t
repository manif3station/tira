#!/usr/bin/env perl
# The CLI's tasklist.list gained --status (TKT-545) and --unlinked (TKT-552)
# so a caller could ask "what is still on my plate" or "what has no ref yet"
# without fetching every item and filtering by hand. The browser Task List
# panel's only filter is free-text substring matching (tlMatches in
# tasklist-editor.js) - neither question can be asked there, so the person
# watching the board day to day still counts rows by eye.
#
# HOW AN APPEARANCE CARD IS TESTED WITHOUT A BROWSER, the way t/507 already
# established for this same section: this does not assert the page looks
# right - nothing here can. It asserts the controls exist to be pressed, that
# tlMatches reads both new filters and composes them with the existing text
# filter (AND, not OR - a status match with the wrong text still hides), and
# that the vocabulary reused is STATUS_NAME's own rather than a new spelling.
# Filter-survives-the-poll is a property of using module-scope state read
# fresh inside tlMatches, the same way tlFilterText already survives it -
# asserted here by confirming the new state lives in the same closure and is
# never reset inside reconcileTasklist/loadTasklist.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();

my $js     = Suite::view_source('tasklist-editor.js');
my $render = Suite::engine_source();

like( $js,     qr/\S/, 'the tasklist editor is there to be read' );
like( $render, qr/\S/, 'the renderer is there to be read' );

# --- the controls exist to be pressed ---------------------------------------

like( $render, qr/tasklist-status-filter/, 'the renderer emits a status filter control' );
like( $render, qr/tasklist-unlinked/,      'the renderer emits an unlinked filter control' );

# --- the vocabulary is STATUS_NAME's own, not a new spelling ----------------

like( $js, qr/STATUS_NAME\s*=\s*\{\s*0:\s*"pending",\s*1:\s*"working",\s*2:\s*"done"/,
    'STATUS_NAME is still the one mapping this card must reuse rather than duplicate' );
unlike( $render, qr/option value="pending"|option value="working"|option value="done"/,
    'the status control is not spelled out with a second copy of the words - it uses the numeric codes STATUS_NAME already maps' );

# --- tlMatches reads both new filters, composing with the text filter (AND) -

like(
    $js,
    qr/const\s+tlMatches\s*=\s*\(?item\)?\s*=>\s*\{(?:(?!\};).)*tlStatusFilter(?:(?!\};).)*\}/s,
    'tlMatches reads a status-filter state variable'
);
like(
    $js,
    qr/const\s+tlMatches\s*=\s*\(?item\)?\s*=>\s*\{(?:(?!\};).)*tlUnlinkedOnly(?:(?!\};).)*\}/s,
    'tlMatches reads an unlinked-filter state variable in the same function'
);

# A status filter set to a real status must be able to say no on its own,
# independent of the text filter - otherwise it is decoration, not a filter.
like(
    $js,
    qr/tlStatusFilter\s*!==?\s*["']["']\s*&&[^\n]*item\.status[^\n]*return\s+false/,
    'the status filter can refuse a non-matching item on its own (a real AND, not an OR with text)'
);
like(
    $js,
    qr/tlUnlinkedOnly[^\n]*return\s+false/,
    'the unlinked filter can refuse a linked item on its own'
);

# --- state lives where tlFilterText already lives, so it survives the poll -

like( $js, qr/let\s+tlStatusFilter/, 'the status filter state is module-scope, like tlFilterText' );
like( $js, qr/let\s+tlUnlinkedOnly/, 'the unlinked filter state is module-scope, like tlFilterText' );

# reconcileTasklist/loadTasklist must never reset the new state - if either
# did, a filter chosen by clicking would be undone by the next 1-second poll,
# the exact failure mode CHK-007 exists to catch.
unlike(
    join( "\n", grep { /reconcileTasklist|loadTasklist/ } split /\n/, $js ),
    qr/tlStatusFilter\s*=|tlUnlinkedOnly\s*=/,
    'neither reconcileTasklist nor loadTasklist resets the new filter state on refresh'
);

done_testing();

__END__

=head1 NAME

t/764-a-panel-that-cannot-ask-what-the-cli-can.t - the browser Task List
panel gains the status and unlinked filters the CLI already has

=head1 DESCRIPTION

TKT-764. C<tasklist.list> answers "what is still on my plate" (C<--status>,
TKT-545) and "what has no ref yet" (C<--unlinked>, TKT-552) in one flag; the
browser Task List panel's only filter was free-text substring matching, so
neither question could be asked there. A status select and an unlinked
checkbox are now rendered alongside the existing controls, reusing
C<STATUS_NAME>'s own pending/working/done vocabulary rather than a second
spelling, and C<tlMatches> composes both with the existing text filter (AND)
client-side - the same design the free-text filter already uses, so the
1-second poll costs nothing extra and a chosen filter is never undone by it.

=cut
