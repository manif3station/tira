#!/usr/bin/env perl
# TKT-831. lib/Tira/views/tasklist-editor.js runs an unattended autoPrune
# timer every 5 minutes that calls doPrune() directly, bypassing the
# confirm("Prune every done task?") guard the manual button carries. Any
# browser tab left open on the dashboard silently deletes every done
# tasklist item board-wide, unattended - including another session's own
# gate evidence, measured 13 seconds after one item was marked done.
#
# THE FIX IS DELETION, not a guard added to the timer: an unattended timer
# cannot meaningfully show a human a confirm() dialog, so pruning must only
# ever happen through the one button that already asks.
#
# WRITTEN RED.

use strict;
use warnings;

use lib 't/lib';
use Suite ();
use Test::More;

my $source = Suite::view_source('tasklist-editor.js');

ok( length $source, 'the tasklist editor view exists' );

unlike( $source, qr/setTimeout\([^)]*autoPrune/,
    'no timer schedules an unattended prune - pruning happens only through '
      . 'the confirm()-gated button' );

unlike( $source, qr/function autoPrune/,
    'the autoPrune function itself is gone, not merely unscheduled' );

# --- the manual, confirm-gated path is untouched -----------------------------

like( $source, qr/confirm\("Prune every done task\?"\)/,
    'the manual Prune button still asks before it acts' );

like( $source, qr/tasklist-prune.*addEventListener\("click"/s,
    'and the click handler that owns that confirmation still exists' );

done_testing();

__END__

=head1 NAME

831-a-prune-nobody-confirmed.t - the tasklist editor no longer prunes
unattended

=head1 DESCRIPTION

TKT-831. C<lib/Tira/views/tasklist-editor.js> ran
C<setTimeout(function autoPrune(){doPrune();setTimeout(autoPrune,300000)},300000)>,
calling the same C<doPrune()> the manual Prune button calls but skipping
its C<confirm()> guard entirely - a tab left open silently deleted every
done tasklist item board-wide every five minutes, including another
session's own gate evidence. The unattended timer is removed; the manual,
confirm()-gated button is unchanged.

=cut
