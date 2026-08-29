#!/usr/bin/env perl

# The engine says done and the page says not done, about the same item.
#
# The browser dashboard decides whether a required action is finished with
# entry.status === "done", case-sensitive, in three places: the done/total
# count, the tick-or-empty-box icon, and whether an actionable checkbox is
# drawn. The engine decides the same question with lc($_->{status}) eq 'done',
# case-insensitive, deliberately and with the reason recorded - TKT-434 made it
# so because "--status Done" must not be "refused forever with a message that
# names the very word the person already used".
#
# So an item stored as 'Done' is done to the gate and outstanding to the
# browser. Measured on a copy of a real board, in a container: 534 items stored
# as 'Done' against 2068 as 'done', mis-rendering across 21 cards. ZSD-286 and
# ZSD-287 each show 97 of 97 required actions as empty boxes while being
# provably complete - their items carry proof arrays and their cards carry
# gate_passing_log entries.
#
# THE THIRD COMPARISON IS THE HARMFUL ONE, and it is why this is not a display
# bug. The count and the icon mislead. The checkbox INVITES: it offers a live
# control to complete work that is already complete, and ticking it re-runs
# required_item_update on a done item, which since 4.48 can meet the
# duplicate-proof refusal. The page can walk somebody into a refusal by showing
# them a box that should not have been there.
#
# What this file does NOT decide, because the card deliberately leaves it open:
# whether the fix is one shared predicate or three corrected comparisons. The
# assertions below say what must be TRUE of the result - no case-sensitive
# comparison survives, and done-ness is read case-insensitively - and say
# nothing about how. Three independent copies is how one of them came to
# disagree in the first place, so a helper is very likely right; it is still a
# decision for the implementation rather than a shape pinned by a test.
#
# The dashboard JS is a literal inside lib/Tira.pm, so it is read from the
# source the way t/416 reads the shell tools - with the module's POD stripped
# first, because documentation that quotes the old comparison in order to
# explain the new one is correct prose and must not fail a test about code.
# That catches the comparison existing at all. It cannot catch what the page
# DOES with it - that is the card's sixth acceptance criterion and belongs to a
# real browser, in t/playwright/mixed-case-done.js.

use strict;
use warnings;

use File::Spec;
use Test::More;

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

my $file = slurp('lib/Tira.pm');

# POD stripped before anything is counted, and this is not tidiness - the first
# version of this file counted the whole module and went red the moment the
# change was DOCUMENTED. The POD added for TKT-601 quotes the old comparison
# while explaining what replaced it - "rather than each testing
# entry.status === "done" for themselves" - which is exactly the sentence a
# reader needs and exactly the string this file forbids.
#
# The subject here is the code. Prose that quotes the old form to explain the
# new one is correct and must not fail; a live comparison must. So the counts
# below run over the module with its POD removed, and the assertions say what
# they always meant rather than what a whole-file grep happened to catch.
like( $file, qr/^package Tira;/m, 'the module was read' );

# TKT-703 moved the dashboard's front-end out of lib/Tira.pm into
# lib/Tira/views, so every count below is taken over the scripts themselves.
# The POD stripping this used to need is gone with it: a .js file has neither
# POD nor Perl comments to confuse a count, which is what the note above was
# working around.
my $views = File::Spec->catdir( 'lib', 'Tira', 'views' );
opendir my $dh, $views or die "$views: $!";
my @scripts = sort grep { /\.js\z/ } readdir $dh;
closedir $dh;
my $source = '';
for my $name (@scripts) {
    open my $sh, '<:encoding(UTF-8)', File::Spec->catfile( $views, $name )
      or die "$name: $!";
    local $/;
    $source .= <$sh>;
    close $sh;
}

# Established before anything is denied. Every count below is a claim that
# something is ABSENT, and a count of zero taken over a file that failed to
# load is zero for the wrong reason - which is t/147's whole subject. This
# anchor did exactly that job when the scripts moved: it failed loudly instead
# of letting the counts pass over a file that no longer held the code.
like( $source, qr/card-required/,
    'the dashboard scripts were read and carry the required-action section' );
cmp_ok( length $source, '>', 50_000,
    'and it is the whole front-end - ' . scalar(@scripts) . ' files, '
      . length($source) . ' bytes' );

# --- the three case-sensitive comparisons ----------------------------------
#
# Counted rather than denied, and counted separately for the two operators,
# because the fault is three places and a partial fix that left one is the
# likely outcome. A single denial would go green on two of three.

my $equal    = () = $source =~ /\bstatus\s*===\s*"done"/g;
my $notequal = () = $source =~ /\bstatus\s*!==\s*"done"/g;

is( $equal, 0,
    'nothing in the dashboard tests a status for equality with the literal "done"' );
is( $notequal, 0,
    'and nothing tests it for inequality either' );

# --- and done-ness is decided the way the engine decides it ----------------
#
# At least one, not exactly three: the card leaves open whether the three sites
# share a predicate or each lowercase for themselves, and a count of three
# would fail the shared-helper answer while a count of one would fail the
# three-corrections answer. What both must have is the lowercasing.

my $insensitive = () = $source =~ /toLowerCase\(\)\s*===\s*"done"/g;
cmp_ok( $insensitive, '>=', 1,
    'done-ness is decided case-insensitively, as the engine decides it' );

# --- the three sites are all still there -----------------------------------
#
# A fix that deleted a comparison rather than correcting it would satisfy the
# denials above. Each site is named by something structural that has nothing to
# do with the comparison, so these hold whichever shape the fix takes.

like( $source, qr/required_items\.filter\(/,
    'the done/total count is still computed' );
like( $source, qr/\\u2705.{0,40}\\u2b1c|\\u2b1c.{0,40}\\u2705/,
    'the tick and the empty box are both still rendered' );
like( $source, qr/dataset\.requiredActionDone/,
    'and an outstanding item is still offered its checkbox' );

# --- the exempt state survives ---------------------------------------------
#
# Three states, not two: exempt renders a dash and is struck through, and it is
# decided before done-ness. A fix that collapsed the icon to a boolean would
# lose it, and the card's fifth acceptance criterion is that it does not.

like( $source, qr/\\u2796/,
    'an exempted item still renders its own mark rather than a tick or a box' );

# --- and the checklist renderer is not touched -----------------------------
#
# Measured, not assumed: the checklist prints "[" + status + "]" verbatim and
# compares nothing, so it is honest about whatever value it holds and is
# outside this card. Asserted so that a fix which went looking for "status" and
# corrected everything it found would fail here rather than quietly change a
# renderer that was already right.

like( $source, qr/\Q"["+(entry.status||"open")+"] "\E/,
    'the checklist still prints the status it was given, and compares nothing' );

done_testing();

__END__

=head1 NAME

t/417-a-tick-the-engine-gives-and-the-page-withholds.t - the dashboard must read
a required action's status the way the engine does

=head1 DESCRIPTION

The engine compares a required action's status against C<done>
case-insensitively and has done since TKT-434, deliberately: C<--status Done>
must not be refused forever with a message naming the word the person just
used. The browser dashboard never got the same fix and compares against the
literal C<"done"> in three places - the done/total count, the icon, and whether
a checkbox is drawn.

An item stored as C<Done> is therefore finished to the gate and outstanding to
the page. Measured on a copy of a real board: 534 such items against 2068
lowercase ones, mis-rendering across 21 cards, two of which show every one of
their 97 required actions as an empty box while being provably complete.

The checkbox is the harmful one. It offers a live control to redo finished
work, and since 4.48 taking it up can meet the duplicate-proof refusal - so the
page can lead somebody into a refusal with a control that should not have been
drawn.

This file asserts the outcome and not the shape: no case-sensitive comparison
survives, done-ness is read case-insensitively, all three sites still exist,
the exempt state still renders, and the checklist renderer - which prints the
raw status and compares nothing - is left alone. Whether the fix is one shared
predicate or three corrections is the card's own open decision.

What the source cannot show is what the page DOES, which is the card's sixth
acceptance criterion and lives in C<t/playwright/mixed-case-done.js>.

=cut
