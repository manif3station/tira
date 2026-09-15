#!/usr/bin/env perl

# TKT-784. SKILLS.md's TKT-750 paragraph says the work log "draws a bare
# divider line before each entry where the card changed column" - with no
# qualifier saying WHERE. Read as a universal work-log property, which it
# is not: TKT-750's own accepted acceptance_criteria scoped the divider to
# the browser card dialog alone ("The separator appears in the browser
# card dialog, which is where he was reading it"), and its CLI deliverable
# ("The same in the CLI rendering, if it reads well") was conditional and
# was never implemented. The divider exists only in
# lib/Tira/views/live-helpers.js's own rendering of a 'moved' entry.
#
# THE COST WAS REAL, NOT HYPOTHETICAL: asked which ticket added the
# separator and whether it shipped, this same ambiguous wording produced
# an answer overstating CLI support ("a dashed line in the CLI view" -
# there is none).
#
# WRITTEN RED.

use strict;
use warnings;

use List::Util qw(max);
use Test::More;

my $skills = do {
    open my $fh, '<:encoding(UTF-8)', 'SKILLS.md' or die "SKILLS.md: $!";
    local $/;
    <$fh>;
};

# Bounded to ONE paragraph (up to the next blank line, SKILLS.md's own
# paragraph separator), not an unbounded dotall span that could cross into
# unrelated later text - Codex review found the first version could start
# at any "Since 4.83" and run to any later "TKT-784.", regardless of
# whether they belonged to the same paragraph, and never required TKT-750
# to appear at all.
my ($paragraph) = $skills =~
  /(Since 4\.83 the [^\n]*draws a bare divider line.*?)\n\n/s;
ok( defined $paragraph && $paragraph =~ /\bTKT-750\b/,
    'the TKT-750 divider paragraph is found in SKILLS.md, as one bounded '
      . 'paragraph naming TKT-750 - not any span between two unrelated '
      . 'mentions of similar text' );
$paragraph //= '';

like( $paragraph, qr/\bbrowser\b|\bcard dialog\b/i,
    'the paragraph names the browser card dialog explicitly, rather than '
      . 'describing a universal work-log property the CLI does not have' );

# --- and the claim matches what the CLI actually does today ----------------
#
# Not just documentation wording in isolation - the real behavior it
# describes. If a future ticket genuinely adds a CLI divider, this
# assertion is what should change, on that ticket, not silently.

# The rendering split in this codebase is by FILE TYPE, not file name:
# lib/**/*.pm is the CLI-facing engine, lib/**/views/*.js is the browser -
# that split is what makes "no .pm source draws it" a real proxy for
# "the CLI has no divider", checked by walking every .pm file under lib/
# rather than guessing which one might be relevant by name.
my @pm_sources;
{
    require File::Find;
    no warnings 'once';
    File::Find::find( { no_chdir => 1, wanted => sub {
        push @pm_sources, $File::Find::name if /\.pm\z/;
    } }, 'lib' );
}
cmp_ok( scalar @pm_sources, '>=', 10,
    'lib/ was walked for every Perl module - ' . scalar(@pm_sources) . ' found' );

# Matched as "divider/separator" within a genuinely bounded 150-CHARACTER
# WINDOW of "moved" or "worklog" - lib/Tira/CLI.pm's own PATH separator has
# nothing to do with the work log, and a bare-word search would wrongly
# flag it as a false positive. Codex review found the first version's
# {0,200} bound was defeated by an unbounded .* inside the very pattern it
# was meant to constrain (kind.*moved, under /s); this checks the window
# with substr on the match position instead of trusting a single regex to
# enforce its own proximity claim. This is a source-text proxy for the
# CLI's real output, the same limitation every doc-vs-code guard in this
# suite (t/433, t/876, t/1098) already carries and documents rather than
# solves - a divider added without either word, or added and described in
# code that never uses them, would not be caught here.
my @divider_sources;
for my $source (@pm_sources) {
    open my $fh, '<:encoding(UTF-8)', $source or die "$source: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    while ( $text =~ /divider|separator/ig ) {
        my $window = substr( $text, max( 0, pos($text) - 150 ), 300 );
        if ( $window =~ /work.?log|\bmoved\b/i ) {
            push @divider_sources, $source;
            last;
        }
    }
}
is_deeply( \@divider_sources, [],
    "no lib/ Perl module (the CLI-facing engine) draws a work-log "
      . 'divider/separator - confirms the browser-only claim this paragraph '
      . 'makes is still true; if this ever flips, the paragraph and this '
      . 'assertion need updating together, not the paragraph alone' );

done_testing;

__END__

=head1 NAME

1101-a-divider-drawn-somewhere-unsaid.t - SKILLS.md's work-log divider claim names where

=head1 WHY

TKT-784. SKILLS.md's TKT-750 paragraph described the work-log divider with
no browser/CLI qualifier, reading as a universal property. TKT-750's own
accepted scope was browser-only; the CLI deliverable was conditional and
never built. The gap produced a real wrong answer to the owner, not just a
theoretical ambiguity.

=head1 WHAT IS ASSERTED

The TKT-750 paragraph names the browser card dialog explicitly, and no
lib/ work-log source actually draws a CLI-facing divider - so the
narrowed claim matches the real, current behavior, not just improved
wording in isolation.

=head1 WHAT IS NOT ASSERTED

That the CLI will never gain a divider - if it does, this file's second
assertion is expected to need updating on that same ticket, which is the
point: the two must change together.

=cut
