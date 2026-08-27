#!/usr/bin/env perl
# The documentation argued against its own feature before describing it.
#
# Two adjacent paragraphs, in docs/commands.md and again in SKILLS.md. The
# first: "Starman's own HUP is no help either: its Server.pm overrides
# Net::Server's exec-based sig_hup with one that only recycles workers from
# the master's already-compiled code, so a graceful reload loads nothing new."
# The second: police "sends the master a HUP. Starman re-forks its workers on
# HUP, and because Tira serves a .psgi file path rather than an in-memory
# coderef, each new worker re-reads the modules from disk and comes up on the
# installed version."
#
# Both cannot be true. The second is the one that is, and TKT-566's docker
# integration test proves it against a real board in developer-dashboard:
# latest - same master pid, every pre-signal worker gone, still serving, which
# is only possible if HUP reloaded the code in place.
#
# The first paragraph is the residue of a belief held before TKT-565: that
# Starman's HUP only recycles workers from already-compiled code, read off
# Starman::Server's sig_hup override and not carried any further. The owner
# said HUP would work; a real two-worker Starman settled it (served "one",
# changed the file, HUP, served "two"). The correction was then written into
# the docs AFTER the wrong paragraph instead of in place of it, so both
# survived.
#
# The cost of leaving it is specific rather than tidiness: a reader who stops
# at the first paragraph reaches exactly the conclusion that cost the most
# time here - that HUP is useless and the automatic pickup cannot work. The
# feature's own documentation talks the reader out of believing in it.
#
# Nothing existing could have caught this. t/70 runs documented EXAMPLES, and
# these are prose; no test compares two paragraphs for agreement. So this file
# is narrow on purpose: it does not try to detect contradiction in general,
# only to hold this one claim, which is load-bearing and was wrong. TKT-564.

use strict;
use warnings;

use Test::More;

my @docs = ( 'docs/commands.md', 'SKILLS.md' );

# Markdown is not the prose it renders to, and matching it raw is how this
# test first passed while both documents still carried the sentence: `HUP`
# defeats /HUP/ with its backticks, and "loads nothing new" was split across a
# line break. Normalising first - backticks out, all whitespace to single
# spaces - is what makes an assertion here mean what it says.
sub prose {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    my $text = <$fh>;
    $text =~ s/`//g;
    $text =~ s/\s+/ /g;
    return $text;
}

for my $doc (@docs) {
    my $text = prose($doc);

    # The claim itself, in the words it was actually written in. Matching the
    # sentence rather than the word "HUP" keeps this from firing on every
    # legitimate mention - the document should discuss HUP at length, and does.
    # ok() on a boolean rather than unlike(): a failing unlike() prints the
    # string it matched against, and that string is an entire normalised
    # document. The first run of this test emitted 175KB of diagnostic for two
    # failures, which buries the answer it exists to give.
    ok( $text !~ /HUP is no help/i,
        "$doc does not say Starman's HUP is no help" );
    ok( $text !~ /a graceful reload loads nothing new/i,
        "$doc does not say a graceful reload loads nothing new" );

    # And the true statement is still there, so this cannot be satisfied by
    # deleting the whole discussion instead of correcting it.
    ok( $text =~ /re-reads the modules from disk/i,
        "$doc still explains that a re-forked worker re-reads from disk" );

    # The real limitation has to survive too. The shipped board genuinely
    # cannot restart itself - the master owns the socket and only workers
    # serve - and that is WHY police signals from outside. Losing it would
    # leave the reader wondering why anything external is needed at all.
    ok( $text =~ /owns the listening socket|master owns the socket/i,
        "$doc still explains why the board cannot restart itself" );
}

done_testing;

__END__

=head1 NAME

405-a-document-that-argues-with-itself.t - the HUP claim that contradicted itself

=head1 DESCRIPTION

C<docs/commands.md> and C<SKILLS.md> each carried two adjacent paragraphs that
disagreed about whether sending Starman a C<HUP> loads new code. It does, which
is what the police-driven pickup depends on and what TKT-566's integration test
proves. These assertions hold the corrected claim in both documents, and hold
the separate, true limitation - that the shipped board cannot restart itself,
because the master owns the listening socket - so the fix cannot be satisfied by
deleting the discussion rather than correcting it.

=cut
