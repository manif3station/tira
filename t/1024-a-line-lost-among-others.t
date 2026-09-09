#!/usr/bin/env perl
# TKT-1024. Michael's TG msg #7798, live: the bridge panel's own dense wall
# of lines has no visual separation, hard to scan at a glance. His words:
# "each line will have a flip flop colour strip to determine line by line
# at first glance." A follow-up comment on the card itself (CMT-001) widened
# this to the jobs card log panel too, not only the bridge panel.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 't/lib';
use Suite ();

# --- the bridge panel --------------------------------------------------------
#
# Both class literals, not an alternation either alone would satisfy - a
# render that only ever emitted "even" (index never truly alternating) must
# fail this, not pass on the shape of one branch.

my $bridge = Suite::view_source('bridge-panel.js');
ok( length $bridge, 'the bridge panel script was read' );
like( $bridge, qr/bridge-line--even/, 'the bridge panel stamps an even-line class' );
like( $bridge, qr/bridge-line--odd/,  'and an odd-line class' );
like( $bridge, qr/const\s+line\s*=\s*\(\s*entry\s*,\s*index\s*\)/,
    'line() actually receives an index to alternate on, not a hard-coded branch' );
like( $bridge, qr/forEach\(\s*\(\s*entry\s*,\s*index\s*\)\s*=>\s*bridgeList\.appendChild\(\s*line\(\s*entry\s*,\s*index\s*\)/,
    'and the render loop passes that index through on every call' );

# --- the jobs card log panel, Michael's own scope-widening comment ----------

my $editor = Suite::view_source('jobs-editor.js');
ok( length $editor, 'the jobs editor script was read' );
like( $editor, qr/jobs-card__log-line--even/, 'the job log panel stamps an even-line class too' );
like( $editor, qr/jobs-card__log-line--odd/,
    'and an odd-line class, per his own live comment: "Also apply to the '
      . 'bridge log section on the dashboard. not only on the job card"' );
like( $editor, qr/forEach\(\s*\(\s*entry\s*,\s*index\s*\)\s*=>/,
    'the job log render loop also receives an index to alternate on' );

# --- the CSS actually paints something different, and as a full-line strip --

my $css = Suite::view_source('dashboard.css');
ok( length $css, 'the dashboard stylesheet was read' );
like( $css, qr/\.bridge-line--odd\s*\{[^}]*background/s,
    'the stylesheet paints a background for the bridge panel\'s odd lines' );
like( $css, qr/\.jobs-card__log-line--odd\s*\{[^}]*background/s,
    'and for the job log panel\'s odd lines' );

# The job log renders <span> (inline) inside a <pre>, unlike the bridge
# panel's block-level <div> lines - an inline background sits only behind
# the glyphs, not as a full-width strip across the line. Caught by Codex
# review before this shipped.
like( $css, qr/\.jobs-card__log-line--(?:odd|even)[\s,]*(?:\.jobs-card__log-line--(?:odd|even))?\s*\{[^}]*display:\s*block/s,
    'the job log line classes are forced block-level so the stripe spans the full line width, not just the text glyphs' );

# Once display:block gives each span its own line, an appended "\n" under
# white-space:pre-wrap would preserve as a spurious blank line inside the
# block. Caught by Codex review as a follow-on to the display:block fix.
unlike( $editor, qr/entry\.line\s*\+\s*["']\\n["']/,
    'no newline is appended to a job-log line\'s own text - the now-block-level span already breaks the line' );

done_testing();

__END__

=head1 NAME

t/1024-a-line-lost-among-others.t - bridge and job log lines alternate a
background colour for line-by-line readability

=head1 DESCRIPTION

TKT-1024. Neither the bridge panel (C<bridge-panel.js>) nor the job card's
own log panel (C<jobs-editor.js>) marked a rendered line as odd or even, so
a dense dump of violation or output lines had no visual rhythm to scan
against - his own words, "a flip flop colour strip to determine line by
line at first glance". Both panels now stamp an odd/even class per line,
and C<dashboard.css> paints a subtly different background for each,
scoped to both panels per his own live follow-up comment widening this
past the bridge panel alone.

=cut
