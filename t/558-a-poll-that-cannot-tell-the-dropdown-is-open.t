#!/usr/bin/env perl
# TKT-600. TSK-175, his own words: "when i select the status of a task card.
# the drop down will disappear because the card rebuild or refresh itself."
#
# THE POLL REBUILDS EVERY SECOND, and reconcileTasklist() keeps a row's own
# DOM node across a rebuild only when tlRowBusy() says the row is busy - the
# same mechanism that already protects a card being retitled (an open
# textarea), a CARD-REF being typed, and a file mid-attach. It never learned
# about the status `<select>`: opening its native dropdown focuses the
# select without touching the DOM tlRowBusy actually inspects, so the next
# poll - up to a second later - treats the row as idle, rebuilds it, and the
# open dropdown vanishes with the element it belonged to.
#
# WHAT MUST NOT BREAK: the poll still has to notice a change to a row nobody
# is touching, and the CARD-REF/file-input busy checks TKT-590/554 already
# protect must keep working exactly as they do today.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();

my $js = Suite::view_source('tasklist-editor.js');
# non-empty is the whole claim: every denial below would pass on an
# unreadable file's emptiness alone otherwise - the fault t/147 exists for.
like( $js, qr/\S/, 'tasklist-editor.js is there to be read' );

# --- established: tlRowBusy exists and already protects two other cases ----

my ($busy) = $js =~ /(const\s+tlRowBusy\s*=.*?;)(?=const\s+reconcileTasklist)/s;
ok( defined $busy && length $busy, 'tlRowBusy is there to read' )
  or BAIL_OUT('tlRowBusy not found by this pattern - update it above');

like( $busy, qr/CARD-REF/, 'still protects a ref being typed, unchanged by this fix' );
like( $busy, qr/type="file"/, 'still protects a file mid-attach, unchanged by this fix' );

# --- THE GAP: nothing here has ever heard of the status select -------------

# qr/select/i alone would pass on "querySelector" - already in this text for
# the CARD-REF and file checks - which is not evidence of anything. It has to
# find a query FOR a select element specifically.
like( $busy, qr/querySelector\((['"])select\1\)/,
    'tlRowBusy also treats the status dropdown as busy - the one input the '
      . 'poll never learned about, which is the whole of this card' );

my ($select_check) = $busy =~ /(querySelector\((['"])select\2\).*)/;
ok( defined $select_check, 'a select lookup was found to check what it does with it' );
like( $select_check, qr/activeElement/,
    'checked the same way the CARD-REF input already is - focus, since a '
      . "native <select>'s open dropdown does not otherwise show up in the DOM" );

done_testing();

__END__

=head1 NAME

558-a-poll-that-cannot-tell-the-dropdown-is-open.t - the 1-second tasklist poll no longer closes an open status dropdown

=head1 DESCRIPTION

TKT-600. C<reconcileTasklist()> polls every second and keeps a row's DOM
node only when C<tlRowBusy()> says so - already true for an open text editor,
a CARD-REF being typed, and a file mid-attach, but never for the status
C<< <select> >>. Opening its native dropdown focuses the element without
otherwise marking the row busy, so the next poll rebuilds it and the open
dropdown disappears with the element it belonged to. C<tlRowBusy> now also
treats the select as busy while it holds focus, the same way the CARD-REF
input already does.

=cut
