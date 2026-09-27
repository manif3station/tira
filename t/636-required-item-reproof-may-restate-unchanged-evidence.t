#!/usr/bin/env perl
# TKT-636. Reported from zen-framework: a card returned to an earlier
# column for a review finding has every required item between destination
# and origin reset to pending (TKT-455, deliberate and correct), and the
# re-walk was assumed to need wholly new evidence for facts that could not
# have changed. That assumption is false: _refuse_reused_proof only refuses
# an EXACT text match on the (command, proof) pair, so a proof honestly
# stating the same evidence still holds is already accepted today. This
# only needed documenting, in SKILLS.md's own TKT-455 paragraph, so an
# agent re-walking a card is not pressured to invent new substance.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use Test::More;

my $skills_md = File::Spec->catfile( '.', 'SKILLS.md' );

open my $fh, '<', $skills_md or die "cannot read $skills_md: $!";
my $text = do { local $/; <$fh> };
close $fh;

# Anchor on the whole paragraph (bounded by blank lines) rather than two
# independent whole-file regexes, so neither assertion can be satisfied by
# an unrelated occurrence elsewhere in the file.
my ($paragraph) = $text =~ /(A column can also name what must be done before a card leaves it:.*?)\n\n/s;
ok( $paragraph, 'found the TKT-455 required-action-reset paragraph in SKILLS.md' );

like(
    $paragraph,
    qr/TKT-455\.\s+A reset item can be re-marked `done` by honestly restating unchanged evidence, without inventing new substance/,
    'that paragraph explicitly says a re-walked required item\'s proof may honestly restate unchanged evidence rather than needing invented substance'
);

like(
    $paragraph,
    qr/exact match of the stored `\(command, proof\)` pair, not a check of whether the underlying fact changed/,
    'the clarification, in that same paragraph, correctly describes _refuse_reused_proof as an exact-match check, not a semantic one'
);

done_testing();
