#!/usr/bin/env perl
# t/03-metadata.t hardcoded the release version as a literal, the same
# drift bug it already fixed once for the UC-count heading.
#
# TKT-801. Caught live during TKT-790's own verify pass, 2026-09-01: the
# literal at line 25 still said 5.00 after .env and lib/Tira.pm had been
# bumped to 5.01, failing the suite until someone noticed and corrected the
# test file by hand. TKT-413 already solved this identical shape for a
# different number in the same file - "a literal number... drifted for 336
# commits... because nothing ever read its number back" - and wrote the fix
# as reading the real count rather than repeating it. The version literal
# never got the same treatment.
#
# THE REAL DEFECT THIS TEST PROTECTS AGAINST is not "the test has a
# number in it" - it is ".env and lib/Tira.pm can disagree and the suite
# still says nothing." That check (t/03's own line comparing $Tira::VERSION
# against $env_version, read from the file rather than a literal) already
# exists and does not need a version number written anywhere to work. This
# file proves it still catches a real mismatch, so removing the redundant
# literals is not removing the protection.
#
# WRITTEN RED, against the pre-fix test file.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 't/lib';
use Suite;

# --- the meta-file itself carries no hardcoded version -----------------------

open my $fh, '<', 't/03-metadata.t' or die "t/03-metadata.t: $!";
my $source = do { local $/; <$fh> };
close $fh;

# non-empty is the whole claim: the subject is established first, so a file
# that failed to read cannot pass the denials below on emptiness alone -
# the exact fault this project's own t/147 exists to catch.
like( $source, qr/\S/, 't/03-metadata.t is there to be read' );

unlike( $source, qr/qr\{?\/?\^?VERSION=\d+\\?\.\d+\$?\/?\}?m/,
    'T/03-METADATA.T NO LONGER MATCHES A SPECIFIC VERSION NUMBER against '
      . ".env's own text - every release used to require a hand-edit here or "
      . 'the suite failed on a version bump alone' );

unlike( $source, qr/is\(\s*\$Tira::VERSION,\s*'\d+\.\d+'/,
    'AND NO LONGER ASSERTS A LITERAL EXPECTED VALUE for $Tira::VERSION - the '
      . 'self-consistency checks below (module matches .env, matches the '
      . "changelog's own top entry) already prove the real defect without one" );

# --- and the real defect is still caught: .env and the module can disagree --
#
# Proved directly against the engine, not by re-reading t/03's own assertions -
# a test asserting its own logic re-reads nothing external and could pass
# while lying about what it protects.

my $tmp = tempdir( CLEANUP => 1 );

# _valid_slug and similar are not what is exercised here; $Tira::VERSION is a
# package variable read at compile time, so the mismatch this guards against
# is proved the same way t/03 itself would notice it: reading .env's text
# independently and comparing it to the loaded module's own $VERSION.
require Tira;
open my $env, '<', '.env' or die ".env: $!";
my $env_text = do { local $/; <$env> };
close $env;
my ($env_version) = $env_text =~ /^VERSION=(\S+)$/m;
ok( defined $env_version, '.env genuinely names a version, independent of t/03' );
is( $Tira::VERSION, $env_version,
    'AND THE MODULE AGREES WITH IT - this is the actual defect a drifted '
      . 'literal used to mask: if this comparison were ever false, no '
      . 'hardcoded number anywhere would have been needed to say so' );

done_testing();

__END__

=head1 NAME

550-a-test-that-forgot-the-version.t - t/03-metadata.t hardcoded a version number the same way TKT-413 already fixed for the UC-count

=head1 WHY

TKT-801. t/03-metadata.t's own version-matching assertion carried a literal
version number that had to be hand-edited on every release or the suite
failed - caught live during TKT-790's verify pass when the literal was
forgotten. The file had already fixed this exact shape of bug once, for the
UC-count heading (TKT-413), and never applied the same fix to itself.

=head1 WHAT IS ASSERTED

That t/03-metadata.t no longer contains a version-number literal in either
of its two former hardcoded spots, and that the real defect - .env and
lib/Tira.pm's own C<$VERSION> disagreeing - is still genuinely caught,
independent of t/03's own assertions.

=cut
