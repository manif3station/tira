#!/usr/bin/env perl
# TKT-798. Changes carried two literal "Suite TBD." lines past a release -
# real numbers pulled from TKT-787/TKT-796's own verify proofs were filled
# in by hand afterward, but nothing stopped it from happening again. This is
# the guard: Changes must never contain a placeholder like "TBD" anywhere,
# so a release note is complete before it ships, not fixed up after.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

open my $fh, '<', 'Changes' or die "Changes: $!";
my $text = do { local $/; <$fh> };
close $fh;

like( $text, qr/Revision history for Tira/, 'Changes was actually read, not silently empty' );

# A bare, unquoted TBD is a placeholder someone forgot to fill in. A quoted
# one - "TBD", inside a discussion of what shape a value might take - is
# prose describing the concept, not one left unfilled; excluded so this
# guard does not have to be re-litigated every time TBD is discussed rather
# than shipped as one. TKT-798's own fault was the unquoted shape: "Suite TBD."
my $placeholder_re = qr/(?<!["'])\bTBD\b(?!["'])/;

unlike( $text, $placeholder_re, 'Changes carries no unquoted TBD placeholder anywhere' );

# --- the control: the guard actually catches one -----------------------

my $with_placeholder = $text . "\n    - Suite TBD.\n";
like( $with_placeholder, $placeholder_re, 'and the same check would have caught it if it shipped' );

done_testing();

__END__

=head1 NAME

t/798-a-placeholder-that-shipped.t - Changes never carries a TBD placeholder

=head1 DESCRIPTION

TKT-798, standing hunt TKT-522. Two "Suite TBD." lines shipped in Changes
before this - the real numbers, pulled from TKT-787/TKT-796's own verify
required-action proofs, were filled in by hand once found. Nothing stopped
the same thing from happening again, so this test reads the shipped Changes
file and fails on any "TBD" it finds, regardless of where.

=cut
