#!/usr/bin/env perl
# The POD has to say how many guards stand on the move path.
#
# lib/Tira/CLI.pm runs four of them back to back, and any one can refuse a
# move. Its POD documents one. That entry opens by naming a second as "its
# mirror image", which tells a reader the set is a pair - so the only guard
# with an entry is also the sentence that misleads about the total.
#
# The two with no entry at all are the two a reader is least likely to guess:
# _column_chain_violation, which enforces that a card passed through the
# columns the board defines, and _unjudged_answer_violation, which refuses a
# move while an answer sits unjudged. An agent reading this file to find out
# why its move was refused is told about one guard out of four.
#
# THE GUARD LIST IS DERIVED FROM THE CODE, NOT WRITTEN OUT HERE. That is what
# CHK-006 asks for and it is the difference between a test that pins today's
# four names and one that keeps working: a fifth guard added to the move path
# without an entry fails this file, and nobody has to remember to update it.
# A list written by hand would have to be maintained by exactly the discipline
# that failed here in the first place.
#
# The order matters as much as the count, and is the fact hardest to guess from
# the code: the guards return early, so the FIRST to refuse is the only message
# a caller ever sees. Entry required actions are checked LAST, after the chain,
# the exit actions and the unjudged answer - the opposite of what a reader
# would assume from a pair called entry and exit.

use strict;
use warnings;

use Test::More;

my $file = do {
    open my $fh, '<', 'lib/Tira/CLI.pm' or die "lib/Tira/CLI.pm: $!";
    local $/;
    <$fh>;
};

# Established before anything is counted. Every assertion below is about this
# text, and a count taken over a file that failed to load is zero for the wrong
# reason - t/147's subject, and the thing that made t/417 fail loudly rather
# than silently when the front-end moved out of lib/Tira.pm.
ok( $file, 'lib/Tira/CLI.pm was read - ' . length($file) . ' bytes' );

my ($pod) = $file =~ /^(=head1 NAME.*)\z/ms;
ok( $pod, 'and its POD was found - ' . length( $pod // '' ) . ' bytes' );

# --- what actually runs on the move path -------------------------------------

my @guards = $file =~ /my \$\w+ = (_\w+_violation)\(\s*\$tira,\s*%args\s*\)/g;
cmp_ok( scalar @guards, '>=', 4,
    'the move path calls at least four guards - found '
      . scalar(@guards) . ': ' . join( ', ', @guards ) );

# --- and every one of them says what it refuses -------------------------------
#
# One assertion per guard rather than a count, so a failure names the guard
# that has no entry instead of reporting that some number is wrong.

for my $guard (@guards) {
    like( $pod, qr/^=head2 \Q$guard\E$/m,
        "$guard has a POD entry saying what it refuses" );
}

# --- the size of the set is stated, not left to be inferred -------------------

like( $pod, qr/four guards/i,
    'the POD says how many guards run on a move, so a reader learns the size '
      . 'of the set rather than inferring it from whichever entry they read '
      . 'first' );

# --- and nothing calls the set a pair -----------------------------------------
#
# Declared: this denial is about a phrase that must be absent, and its absence
# is the fix rather than an accident. The sentence is the fault, not merely an
# omission beside it - the only documented guard introduces a second by name
# and stops there.

# Matched across whitespace, because the POD wraps and the phrase sits on two
# lines as "Its mirror\nimage,". The first version of this assertion searched
# for the exact string, found nothing, and PASSED - a denial that was green
# while the sentence it denies was three lines above it. Caught by running the
# file and noticing that one of the four faults reported itself as already
# fixed.
unlike( $pod, qr/mirror\s+image/i,
    'no entry frames the set as a matched pair' );

done_testing();

__END__

=head1 NAME

t/428-four-guards-and-one-entry.t - the move path's guards must all be
documented, and the POD must say how many there are

=head1 DESCRIPTION

C<lib/Tira/CLI.pm> runs four guards on every move and any one of them can
refuse it. Its POD documents one, and that entry opens by calling another "its
mirror image" - so the single documented guard is also the sentence that tells
a reader the set has two members.

The undocumented ones are the two hardest to guess: C<_column_chain_violation>,
which enforces that a card passed through the columns the board defines, and
C<_unjudged_answer_violation>, which refuses a move while an answer sits
unjudged.

The guard list is derived from the source rather than written out here, which
is what makes this a guard rather than a snapshot: a fifth guard added to the
move path without a POD entry fails this file, and no one has to remember to
add it. A hand-written list would need maintaining by the same discipline that
failed here.

The order is the fact worth documenting beyond the count. The guards return
early, so the first to refuse is the only message a caller sees, and entry
required actions are checked last - after the chain, the exit actions and the
unjudged answer - which is the opposite of what "entry and exit" suggests.

=cut
