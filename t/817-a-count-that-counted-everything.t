#!/usr/bin/env perl
# TKT-817, TKT-520 standing bug hunt. The header's task count
# (refreshTaskTotal in hero-counts.js) sets taskTotal to the length of
# whatever /tasklist returns - every item, including ones already marked
# done and never pruned. The header is meant to say how much work is
# outstanding, the same as the questions count beside it; a done item sitting
# unpruned inflates that number for no reason a reader can see.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 't/lib';
use Suite ();

my $header = Suite::view_source('hero-counts.js');
ok( length $header, 'the header script was read' );

# The bug, read directly rather than inferred: today's line sets taskTotal
# from the raw array length, with nothing between the fetch and the count
# that looks at each item's own status.
unlike( $header, qr/taskTotal\s*=\s*Array\.isArray\(list\)\s*\?\s*list\.length/,
    'the task total is no longer the raw, unfiltered array length' );

like( $header, qr/status/,
    'and the fix reads each item\'s own status - the field that distinguishes '
      . 'outstanding work (pending/working) from a done item nobody pruned' );

# Codex review: outstanding_summary (lib/Tira.pm) defaults a missing status to
# pending via `$_->{status} // 0`, so a record with no status field at all is
# still counted there. The header must agree, not silently exclude it.
like( $header, qr/status\s*\?\?\s*0/,
    'a missing item.status defaults to pending, matching outstanding_summary\'s '
      . 'own $_->{status} // 0 fallback in lib/Tira.pm - not silently excluded' );

done_testing();

__END__

=head1 NAME

t/817-a-count-that-counted-everything.t - the header's task count excludes
done items

=head1 DESCRIPTION

TKT-817. C<refreshTaskTotal> in C<hero-counts.js> counted every item
C</tasklist> returned, including ones already marked done and left
unpruned - the header is meant to say how much work is outstanding, the
same as the questions count beside it, and a done item inflates that
number for no reason a reader can see. Fixed by counting only items whose
status is pending or working.

=cut
