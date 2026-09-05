#!/usr/bin/env perl
# The expect-every field's label said what it takes and never what it is for.
#
# TKT-918. His own words, Telegram 6797: "what this 'Expect a line every
# (minutes, blank for no expectation)' do? I have not asked for this or I
# forget I did, or I did but you use different approach. Remind me." He did
# ask - Q-115 on TKT-863 - so the feature is his; what failed is the label,
# which names the units and the blank behaviour and never says what the
# field is FOR or what happens when it is filled in.
#
# THREE ACCEPTANCE CRITERIA: the label says what the field is for, not only
# its units; it says what blank means (no expectation, not a default); and a
# monitor's declared expectation is visible on its card afterwards, not only
# in the form - today it only appears once a monitor has gone STALE, so a
# healthy one gives no sign it declared anything at all.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 't/lib';
use Suite;

my $js = Suite::view_source('jobs-editor.js');
like( $js, qr/\S/, 'the jobs editor is there to be read' );

# --- the label says what the field is for -----------------------------------

unlike(
    $js,
    qr/Expect a line every \(minutes, blank for no expectation\)/,
    'THE OLD LABEL IS GONE - it named only units and blank behaviour, which '
      . 'is what left him unable to remember what he had asked for'
);

like(
    $js,
    qr/wedged|stuck|alive.{0,40}stopped|monitor-silent/i,
    'THE NEW LABEL SAYS WHAT THE FIELD IS FOR - telling a wedged monitor '
      . '(process up, polling stopped) from one that is simply quiet, which '
      . 'is the reason monitor-silent exists'
);

like(
    $js,
    qr/blank/i,
    'and still says what leaving it empty means'
);

# --- a declared expectation is visible even when nothing is wrong -----------
#
# Today the heartbeat only mentions expect_every inside the STALE branch -
# "Silent for X, expects every Y min". A monitor that is beating normally
# gives no sign it declared anything, so the one place he could go to check
# what he set shows nothing until the monitor has already gone quiet too long.

like(
    $js,
    qr/beating["'].*?expect_every/s,
    'THE BEATING STATE ALSO MENTIONS expect_every - a monitor\'s declared '
      . 'expectation is visible on its card whether or not it has gone stale'
);

done_testing();

__END__

=head1 NAME

546-a-label-that-forgot-what-it-was-for.t - the expect-every field explained neither its purpose nor its own value when healthy

=head1 WHY

TKT-918. Michael asked what a field he himself had requested (Q-115,
TKT-863) was for, eight hours after asking for it - the label named units
and blank-behaviour and nothing else. Worse, a monitor's declared value was
invisible on its own card until the monitor had already gone stale.

=head1 WHAT IS ASSERTED

That the old bare label is gone; that the new one explains what the field
is for (telling a wedged monitor from a quiet one) and still says what
blank means; and that a monitor's declared expectation is shown even while
it is beating normally, not only once it has gone stale.

=cut
