#!/usr/bin/env perl
# A job card's log panel read oldest-first and force-scrolled to the bottom
# every repaint, unlike the bridge panel (TKT-976), which reads newest-first
# and preserves wherever the reader had scrolled to. His screenshot showed a
# job card that looked like it was "not even showing the latest" - the
# newest line was there, just at the bottom, past whatever was on screen,
# and the panel kept pulling itself back down there on every repaint.
#
# Source-read, the way t/500/t/508/t/510/t/517/t/528/t/530 all read
# jobs-editor.js: this suite drives no browser and browser tests are his.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();

my $editor = Suite::view_source('jobs-editor.js');
ok( length $editor, 'the jobs editor was read' );

my ($paint) = $editor =~ /(const \s paintLog \s* = .*? \n \s* \};)/xs;
ok( defined $paint && length $paint,
    'the paintLog() region was extracted - the function that renders a job\'s log lines' );

unlike( $paint // '', qr/box\.scrollTop\s*=\s*box\.scrollHeight/,
    'paintLog no longer force-scrolls to the bottom on every repaint - '
      . 'that is what buried the newest line off-screen while looking like '
      . 'nothing new had arrived' );

like( $paint // '', qr/\.slice\(\)\.reverse\(\)/,
    'and it renders newest-first, the same construction the bridge panel '
      . 'uses (TKT-976) - slice() first because reverse() mutates in place' );

done_testing();

__END__

=head1 NAME

1018-a-tail-that-buried-the-top.t - a job card's log panel reads
newest-first and stops force-scrolling to the bottom

=head1 DESCRIPTION

TKT-1018. C<jobs-editor.js>'s C<paintLog> rendered a job's kept lines
oldest-first and then set C<box.scrollTop = box.scrollHeight> on every
repaint, pulling the reader back to the bottom even if they had scrolled
up to read something. The bridge panel (TKT-976) already solved this
identical shape - render C<entries.slice().reverse()> so the newest line
is first, and stop fighting the reader's own scroll position. C<paintLog>
now does the same.

=cut
