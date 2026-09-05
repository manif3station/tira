#!/usr/bin/env perl
# --help/usage output, and the two remaining docs, still say "dashboard
# tira.xxx" - a prefix that predates the d2 rename.
#
# TKT-811. TKT-809 fixed README.md's examples to the real d2 prefix, scoped
# to README only. This is everywhere else a user actually encounters the
# wrong prefix: live --help/usage strings first, since those have more
# real-world impact than any doc page, plus SKILLS.md's and
# docs/commands.md's own remaining examples.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 't/lib';
use Suite;

my @SOURCE_FILES = qw(
  cli/usage
  cli/skills
  cli/changes
  lib/Tira/CLI/Usage.pm
  lib/Tira/OnboardWeb.pm
);

for my $file (@SOURCE_FILES) {
    open my $fh, '<', $file or die "$file: $!";
    my $text = do { local $/; <$fh> };
    close $fh;

    # non-empty is the whole claim: an unreadable file would pass the denial
    # below on emptiness alone, which is the exact fault t/147 exists to
    # catch.
    like( $text, qr/\S/, "$file is there to be read" );

    unlike( $text, qr/dashboard tira\./,
        "$file NO LONGER SHOWS THE OLD 'dashboard tira.' PREFIX in its own "
          . 'usage/help text - a user copying an example gets a command '
          . 'that actually runs' );
}

# --- and the two remaining docs ----------------------------------------------

for my $doc (qw(SKILLS.md docs/commands.md)) {
    open my $fh, '<', $doc or die "$doc: $!";
    my $text = do { local $/; <$fh> };
    close $fh;

    like( $text, qr/\S/, "$doc is there to be read" );

    unlike( $text, qr/dashboard tira\./,
        "$doc NO LONGER SHOWS THE OLD 'dashboard tira.' PREFIX - TKT-809 "
          . 'fixed README.md only; this is the rest' );
}

done_testing();

__END__

=head1 NAME

551-a-help-string-that-forgot-its-own-name.t - live --help output and two docs still said "dashboard tira." instead of "d2"

=head1 WHY

TKT-811. TKT-809 corrected README.md's dashboard-prefixed examples to the
real d2 prefix, scoped to README only. The live --help/usage strings a user
actually runs, plus SKILLS.md's and docs/commands.md's own remaining
examples, still carried the old prefix.

=head1 WHAT IS ASSERTED

That none of cli/usage, cli/skills, cli/changes,
lib/Tira/CLI/Usage.pm, lib/Tira/OnboardWeb.pm, SKILLS.md, or
docs/commands.md contains the literal string "dashboard tira.".

=cut
