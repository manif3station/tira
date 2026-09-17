#!/usr/bin/env perl
# Counts in SKILLS.md prose are unchecked except the rule count, and one
# has already drifted.
#
# TKT-968, EPC-007. t/433 holds the police rule count against the engine;
# nothing holds the OTHER claims SKILLS.md makes about this codebase.
# SKILLS.md:2602 says "twenty test files ... call it by that name" about
# Tira::CLI::browser_providers - MEASURED on 2026-09-06 (when this card was
# filed) at twenty-five, and again just now at TWENTY-NINE, since four more
# test files started calling it in the eleven days between. The count is
# both DERIVABLE (a grep answers it) and LOAD-BEARING (the sentence is an
# argument that renaming the entry point is not behaviour-preserving), so
# it deserves the same treatment t/433 gives the rule count: find the claim
# by its SHAPE, not by a sentence somebody thought of, and hold it to a
# fresh count every time this file runs.
#
# WHAT IS NOT TOUCHED: SKILLS.md:2206's "50 callers" claim about
# _epoch_of_datetime. Re-measured here too, and it is CORRECT today (48 in
# lib/Tira.pm, 2 in lib/Tira/Attachment.pm) - the card that found this
# claim suspicious was wrong about it, which this file's own control proves
# rather than assumes.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

# --- how many test files genuinely call it -----------------------------------
#
# Matching the CALL, not the bare word - "browser_providers(" - so a file
# talking ABOUT the entry point (this one, in its own comments and code)
# does not count itself as a caller. Codex review: the bare-word match
# counted this very file, inflating the total by one.

my @callers = grep {
    my $file = $_;
    $file ne '968-a-count-nothing-was-holding.t' && do {
        open my $fh, '<', "t/$file" or die "t/$file: $!";
        local $/;
        my $text = <$fh>;
        close $fh;
        $text =~ /\bbrowser_providers\(/;
    };
} do {
    opendir my $dh, 't' or die "t: $!";
    grep { /\.t\z/ } readdir $dh;
};

my $real_count = scalar @callers;

cmp_ok( $real_count, '>=', 20,
    "browser_providers is genuinely called by test files - $real_count of them" );

# --- the claim in SKILLS.md, found by its shape, not by a fixed sentence ----
#
# A number word ahead of "test files", anywhere in the document - not the
# exact sentence "twenty test files and the dashboard call it by that name",
# which would be blind to any rewording the way t/433's rule-count guard was
# blind to "rules police" until it stopped matching only "rules cover".

my %WORD_NUMBER = (
    one => 1, two => 2, three => 3, four => 4, five => 5, six => 6,
    seven => 7, eight => 8, nine => 9, ten => 10, eleven => 11,
    twelve => 12, thirteen => 13, fourteen => 14, fifteen => 15,
    sixteen => 16, seventeen => 17, eighteen => 18, nineteen => 19,
    twenty => 20, 'twenty-one' => 21, 'twenty-two' => 22,
    'twenty-three' => 23, 'twenty-four' => 24, 'twenty-five' => 25,
    'twenty-six' => 26, 'twenty-seven' => 27, 'twenty-eight' => 28,
    'twenty-nine' => 29, thirty => 30,
);
my $word_alt = join '|', map { quotemeta } sort keys %WORD_NUMBER;

open my $fh, '<', 'SKILLS.md' or die "SKILLS.md: $!";
local $/;
my $text = <$fh>;
close $fh;

# Scoped to near a "browser_providers" mention - "test files" alone is too
# common a shape in this document (it also names how many files a DIFFERENT
# fix touched, elsewhere), and matching every instance would hold sentences
# this card has nothing to do with to a count they were never claiming.
my @claims;
while ( $text =~ /\bbrowser_providers\b/g ) {
    my $mention_pos = $-[0];
    my $near = substr( $text, $mention_pos, 300 );
    next unless $near =~ /\b($word_alt|\d+)\s+test files\b/i;
    my $claimed = $1;
    my $line = 1 + ( substr( $text, 0, $mention_pos ) =~ tr/\n// );
    push @claims, {
        line    => $line,
        claimed => $claimed =~ /^\d+\z/ ? $claimed : $WORD_NUMBER{ lc $claimed },
        raw     => $claimed,
    };
}

cmp_ok( scalar @claims, '>=', 1,
    'SKILLS.md claims a count of test files calling browser_providers - '
      . join( ', ', map { "line $_->{line}: '$_->{raw}'" } @claims ) );

for my $claim (@claims) {
    is( $claim->{claimed}, $real_count,
        "SKILLS.md:$claim->{line} - '$claim->{raw} test files' matches "
          . "the real count grep finds ($real_count)" );
}

# --- the control: the OTHER count this card was filed about is fine --------

my $epoch_callers = 0;
for my $lib_file ( 'lib/Tira.pm', 'lib/Tira/Attachment.pm' ) {
    open my $lfh, '<', $lib_file or die "$lib_file: $!";
    local $/;
    my $lib_text = <$lfh>;
    close $lfh;
    my @found = $lib_text =~ /_epoch_of_datetime\(/g;
    $epoch_callers += scalar @found;
}

# No subtraction for the sub's own definition: "sub _epoch_of_datetime {" has
# no "(" after the name, so /_epoch_of_datetime\(/ never matches it - every
# match here is a genuine call.

cmp_ok( $epoch_callers, '>=', 40,
    "_epoch_of_datetime is genuinely called a lot - $epoch_callers times" );

# NOT wrapped in "if the claim is found" - Codex review: that shape lets a
# reworded or removed claim silently stop being checked, rather than
# failing loudly the way a claim that has drifted numerically does.
# Scoped to name _epoch_of_datetime explicitly, not just "N callers in the
# engine" - Codex review round 2: an unscoped match would let a DIFFERENT,
# unrelated claim of that shape satisfy this check, hiding this one being
# reworded or removed for as long as the other number happened to equal 50.
#
# A wide, punctuation-tolerant gap rather than excluding "." - Codex review
# round 3: a period (or a clause past a smaller budget) between the name and
# the count would otherwise make this fail LOUD as "claim missing" over a
# rewording that changed nothing this test cares about. 400 characters is
# comfortably more than one sentence, so a genuinely different, later claim
# of "N callers in the engine" still cannot be reached from here.
my ($epoch_claimed) =
  $text =~ /_epoch_of_datetime.{0,400}?(\d+)\s+callers in the engine/s;
ok( defined $epoch_claimed,
    "SKILLS.md still claims a count of _epoch_of_datetime's callers - if "
      . 'this fails, the sentence was reworded or removed and this control '
      . 'needs updating to match, not silently dropped' );
is( $epoch_claimed, $epoch_callers,
    "SKILLS.md's '"
      . ( $epoch_claimed // '(not found)' )
      . "' callers claim about _epoch_of_datetime matches the real count "
      . "($epoch_callers) - this card's OWN premise about this number was "
      . 'wrong, which is the control proving so, not merely assuming it' )
  if defined $epoch_claimed;

done_testing();

__END__

=head1 NAME

968-a-count-nothing-was-holding.t - the browser_providers caller count in
SKILLS.md is held to a fresh grep, the way t/433 holds the rule count

=head1 WHY

TKT-968. C<t/433> holds the police rule count against the engine; every other
count SKILLS.md states about this codebase is unchecked, and one had already
drifted from twenty to twenty-five in the eleven days between this card being
filed and worked - twenty-nine by the time it was fixed.

=head1 WHAT IS ASSERTED

That real test files genuinely call C<browser_providers> (the control for the
count that follows), that SKILLS.md's claim is found by the SHAPE of a
number-before-"test files" claim rather than one exact sentence, and that
every claim found matches the real count. Then, as a control rather than a
claim about this change: that C<_epoch_of_datetime>'s own "50 callers" claim
is genuinely correct today, proving rather than assuming that this card's
suspicion about that number was mistaken.

=cut
