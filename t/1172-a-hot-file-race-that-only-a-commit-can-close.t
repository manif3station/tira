#!/usr/bin/env perl
# TKT-1172. This session ran several concurrent agent forks against one
# shared working tree, and a real incident followed: two forks' sequential
# edit-then-commit sequences raced on Changes with no lock or conflict
# detection, and the fork that committed second silently discarded the
# first fork's uncommitted entry. Investigated whether a code-level lock
# (in the style of _with_project_lock/_with_enforcement_lock) could close
# this - it can't: the writers here are editor/agent processes doing plain
# file writes and git commits directly, never calling into lib/Tira.pm, so
# there is no shared code path for a Perl-side mutex to wrap. The
# mitigation is procedural instead: commit an edit to a hot file (Changes,
# .env, lib/Tira.pm) immediately, before starting any other edit to the
# same file. This only needed documenting, in SKILLS.md's own
# "Concurrency and transaction semantics" section, so the next
# concurrent-agent session doesn't rediscover the same race blind.
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
my ($paragraph) = $text =~ /(None of the above locking covers this skill's own source tree\..*?)\n\n/s;
ok( $paragraph, 'found the TKT-1172 hot-file-race paragraph in SKILLS.md' );

like(
    $paragraph,
    qr/TKT-1172/,
    'that paragraph names TKT-1172, the ticket that confirmed the real incident'
);

like(
    $paragraph,
    qr/no shared code path for `_with_project_lock`'s\nstyle of mutex to wrap/,
    'the paragraph explains why a code-level lock was ruled out - no shared code path through lib/Tira.pm'
);

like(
    $paragraph,
    qr/confirmed above by the grep, not\nmerely assumed/,
    'the paragraph says the no-internal-writer claim was verified (grep), not just asserted'
);

like(
    $paragraph,
    qr/commit an edit to `Changes`, `\.env`, or `lib\/Tira\.pm` immediately after/,
    'the paragraph states the accepted procedural mitigation: commit a hot-file edit immediately'
);

like(
    $paragraph,
    qr/it does not close the window/,
    'the paragraph does not oversell the mitigation as closing the race, only narrowing it'
);

done_testing();

=head1 NAME

1172-a-hot-file-race-that-only-a-commit-can-close.t - documents the
concurrent-agent hot-file race and its procedural mitigation

=head1 DESCRIPTION

TKT-1172. A code-level lock for concurrent writers to Changes/.env/lib/Tira.pm
was investigated and ruled out - the writers are editor/agent processes doing
plain file writes and git commits directly, never calling into lib/Tira.pm's
own record-mutation code, so there is no shared code path for a Perl-side
mutex (in the style of C<_with_project_lock>/C<_with_enforcement_lock>) to
wrap. The accepted mitigation is procedural: commit a hot-file edit
immediately, before starting any other edit to the same file. This only
needed documenting, in SKILLS.md's own "Concurrency and transaction
semantics" section.

=cut
