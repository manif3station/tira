#!/usr/bin/env perl
# None of the three log-rendering panels had a clear control - his ask,
# after the ordering/scroll fix in TKT-1018: "make sure there is a clear
# button for any log windows including the bridge too".
#
# Source-read, the way t/500/t/508/t/510/t/517/t/528/t/530/t/1018 all read
# these view files: this suite drives no browser and browser tests are his.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();

# --- job cards: a clear button per card, clearing only that job -----------

{
    my $editor = Suite::view_source('jobs-editor.js');
    ok( length $editor, 'the jobs editor was read' );

    like( $editor, qr/jobs-card__log-clear/,
        'a per-card log-clear button class exists' );

    like( $editor, qr/runLogs\.delete\(\s*job\.id\s*\)/,
        'clicking it removes that job\'s own entry from runLogs, not the whole map' );
}

# --- the request log panel --------------------------------------------------

{
    my $panel = Suite::view_source('logs-panel.js');
    ok( length $panel, 'the logs panel was read' );

    like( $panel, qr/logs-clear/, 'a clear control exists for the request log panel' );

    like( $panel, qr/logsList\.replaceChildren\(\s*\)/,
        'and it empties the rendered list' );
}

# --- the bridge panel --------------------------------------------------------

{
    my $panel = Suite::view_source('bridge-panel.js');
    ok( length $panel, 'the bridge panel was read' );

    like( $panel, qr/bridge-clear/, 'a clear control exists for the bridge panel' );

    like( $panel, qr/bridgeList\.textContent\s*=\s*""/,
        'and it empties the rendered list' );
}

# --- the static markup carries the two header-level clear buttons ---------

{
    my $engine = Suite::engine_source();

    like( $engine, qr/logs-clear/, 'the requests panel markup carries a clear button' );
    like( $engine, qr/bridge-clear/, 'the bridge panel markup carries a clear button' );
}

done_testing();

__END__

=head1 NAME

1020-a-window-with-no-way-to-empty-it.t - every log-rendering panel gets
a clear control

=head1 DESCRIPTION

TKT-1020, split from TKT-1018's fourth acceptance criterion. Each of the
three log panels (job cards, the request log, the bridge) now carries a
clear button. Job cards clear only C<runLogs>' own entry for that job,
since that Map is the client's whole accumulated buffer and other cards
must be unaffected. The request log and bridge panels clear their
current rendering only - both re-fetch from the server every five
seconds regardless, so a clear is a "read it clean right now" control
rather than a retention change, matching his own framing of the ask.

=cut
