#!/usr/bin/env perl
# The number of police rules is stated in three places and checked in one.
#
#   README.md:114     "40 rules police"   correct, and nothing checks it
#   SKILLS.md:2356    "40 rules cover"    correct, and the only one guarded
#   SKILLS.md:868     "36 rules police"   four behind
#
# The engine holds 40. t/03-metadata.t asks:
#
#   my ($claimed) = $skills_text =~ /(\d+) rules cover/;
#
# One phrasing. So every rule ever added has made that guard demand the
# "rules cover" sentence be updated, and said nothing about "the 36 rules police
# itself" two thousand lines earlier, which has sat wrong through four of them.
#
# THE GUARD'S EXISTENCE IS WHAT MADE THE DRIFT INVISIBLE, and that is the reason
# this file is written the way it is. A number nobody checks is obviously
# unreliable and gets re-read. A number that IS checked reads as reliable, so
# nobody looks at the sentence next to it.
#
# WHICH IS WHY THIS DOES NOT ADD A SECOND PHRASING. Alternating "rules cover"
# with "rules police" would be green tomorrow and blind to the third wording the
# day after - the same failure one alternation later. It finds every claim of
# the count by looking for the shape of the claim rather than for a sentence
# somebody thought of, and holds all of them to what the engine reports.

use strict;
use warnings;

use File::Find ();
use Test::More;

use lib 'lib';
use Tira;

my $rules = Tira->new->policy_rules;
cmp_ok( scalar @{$rules}, '>=', 30,
    'the engine reports its rules - ' . scalar( @{$rules} ) . ' of them' );

# --- what counts as a claim --------------------------------------------------
#
# The shape of a claim is a number ahead of the word "rules", with at most two
# words between them:
# "40 rules cover", "40 rules police", "the board has 40 police rules", "there
# are 40 policy rules". Matching a shape rather than a sentence is the whole
# point, and this shape was widened from "<number> rules <verb>" after review
# pointed out that the two noun-phrase forms went unheard. Measured before
# widening rather than after: across all 121 markdown files the broader shape
# returns exactly the same three claims and no false positives, so it costs
# nothing to hold the wordings nobody has written yet.
#
# Deliberately NOT a claim: the same words inside a fenced or indented example.
# Documentation quotes its own past output - sample release evidence, a
# transcript of a police run - and a number in a transcript records what was true
# when it was taken, not what is true now. Holding those to the engine would make
# the guard demand history be rewritten every time a rule is added, and a guard
# that cries wolf is edited out rather than obeyed.

sub _claims_in {
    my ($text) = @_;
    my ( @claims, $fenced, $in_list, $line_number );
    for my $line ( split /\n/, $text, -1 ) {
        $line_number++;

        # A fence opens with at most three leading spaces. Four or more is an
        # indented code block whose first line happens to be backticks, and
        # treating one as a fence inverts every block after it - which is the
        # exact SKILLS.md failure this file exists to catch, so the tool must not
        # reproduce it.
        if ( $line =~ /^ {0,3}(?:```|~~~)/ ) { $fenced = !$fenced; next }
        next if $fenced;

        # Four spaces means an indented example ONLY outside a list. Inside one
        # it is how a paragraph continues, and skipping those let a stale claim
        # hide under a bullet - the original bug, reintroduced by the exemption
        # written to allow transcripts.
        if ( $line =~ /^ {0,3}(?:[-*+]|\d+[.)])\s/ ) { $in_list = 1 }
        elsif ( $line =~ /^ {0,3}\S/ )               { $in_list = 0 }
        next if !$in_list && $line =~ /^(?: {4}|\t)/;

        while ( $line =~ /(\d+)\s+((?:[a-z]+\s+){0,2}rules\b(?:\s+[a-z]+)?)/g ) {
            my ( $claimed, $phrase ) = ( $1, $2 );
            $phrase =~ s/\s+/ /g;
            push @claims, { line => $line_number, claimed => $claimed, verb => $phrase };
        }
    }
    return \@claims;
}

# The control, and it has teeth in both directions: every line below states a
# count, four of them are the document speaking and three are not. Take the fence
# handling out, or the list handling, or the indent rule, and this fails.
#
# The last three are the evasions review found. A claim indented under a bullet
# is a paragraph continuation, not an example; a fence indented four spaces is
# not a fence; and the two noun-phrase wordings were unheard entirely by the
# first version of this guard.
my $fixture = <<'FIXTURE';
The 40 rules police this board.

```
$ d2 tira.police
36 rules police itself   # sample output, taken when there were 36
```

    36 rules police itself   # the same, as an indented block

- A bullet about policing
    the 40 rules police this board, as a list continuation

The board has 40 police rules.

There are 40 policy rules.

    ```
    36 rules police itself   # an indented block that opens with backticks
    ```
FIXTURE

my $fixture_claims = _claims_in($fixture);
is_deeply(
    [ map { $_->{claimed} } @{$fixture_claims} ],
    [ ( '40' ) x 4 ],
    'four claims found and every one of them says 40 - the fenced transcript, '
      . 'the indented one and the indented block that opens with backticks are '
      . 'not claims, and none of the three stale 36s is read as one'
);
is_deeply(
    [ map { "$_->{line}:$_->{verb}" } @{$fixture_claims} ],
    [ '1:rules police', '11:rules police', '13:police rules', '15:policy rules' ],
    'and they are the four expected lines - line 11 is the claim indented under '
      . 'a bullet, 13 and 15 the two noun-phrase wordings the first shape could '
      . 'not hear at all, and every one names where it was found'
);

# --- every document that claims a count -------------------------------------
#
# Walked rather than listed. The claims live in README.md and SKILLS.md today;
# a third document making the same claim tomorrow is the case that started this,
# so naming the files here would rebuild the fault one level up.

my @documents;
File::Find::find(
    {   no_chdir => 1,
        wanted   => sub {
            return if !/\.md\z/;
            return if $File::Find::name =~ m{/(?:cover_db|node_modules|\.git)/};
            push @documents, $File::Find::name;
        },
    },
    '.'
);
cmp_ok( scalar @documents, '>=', 3,
    'the documents were walked - ' . scalar(@documents) . ' markdown files' );

# --- a document whose fences do not close cannot be read at all --------------
#
# FOUND BY THE GUARD ABOVE, not by reading. Skipping fenced examples silently
# dropped SKILLS.md's "40 rules cover" claim, and the reason is a defect in the
# document rather than in the reader: SKILLS.md:1067 ends a prose sentence with
#
#     All are **Implemented.**, with singular assignment semantics updated
#     by ```text
#
# A fence opener has to start its line, so that one does not open anything - the
# nine command lines under it render as prose, and the ``` at 1078 that meant to
# close the block opens one instead. Every fence after it is inverted, which is
# how a claim thirteen hundred lines later ended up inside an example block that
# nobody wrote.
#
# The reader agrees with the renderer here; it is the human eye that silently
# corrects the missing fence. So this is asserted rather than worked around: a
# guard that quietly checks fewer claims than it appears to is the exact fault
# this card is about, one level up.

my @unclosed;
for my $document ( sort @documents ) {
    open my $handle, '<', $document or die "$document: $!";
    my @fences = grep {/^ {0,3}(?:```|~~~)/} <$handle>;
    close $handle;
    push @unclosed, "$document (" . scalar(@fences) . ' fence markers)'
      if @fences % 2;
}
is_deeply( \@unclosed, [],
    'every document\'s fences close, so what this reader skips is what the '
      . 'renderer shows as an example - unclosed: '
      . ( join( ', ', @unclosed ) || 'none' ) );

# --- and every claim of the rule count, however it is worded -----------------

my @claims;
for my $document ( sort @documents ) {
    open my $handle, '<', $document or die "$document: $!";
    my $text = do { local $/; <$handle> };
    close $handle;
    push @claims, map { { %{$_}, document => $document } }
        @{ _claims_in($text) };
}

cmp_ok( scalar @claims, '>=', 2,
    'the documents claim the rule count somewhere - '
      . join( ', ',
        map { "$_->{document}:$_->{line} says $_->{claimed} $_->{verb}" }
        @claims ) );

# Named, not counted. The card's fifth acceptance criterion is that README is
# covered, and a bare ">= 2" is satisfied by SKILLS.md's two claims alone - so
# README could stop being read and every assertion here would stay green. That
# is the same failure this whole file exists for, one level up.
ok( scalar( grep { $_->{document} =~ m{README\.md\z} } @claims ),
    'README.md contributes a claim that is actually checked, rather than being '
      . 'covered only by the guard happening to walk it' );

# One assertion per claim, so a failure names the file, the line and both
# numbers rather than reporting that some count is wrong somewhere.
for my $claim (@claims) {
    is( $claim->{claimed}, scalar @{$rules},
        "$claim->{document}:$claim->{line} - '$claim->{claimed} "
          . "$claim->{verb}' matches what the engine reports" );
}

done_testing();

__END__

=head1 NAME

t/433-a-count-stated-three-times-and-checked-once.t - every claim of the police
rule count, in any document and any phrasing, must match the engine

=head1 DESCRIPTION

The rule count appears three times: C<README.md> and C<SKILLS.md> twice. The
engine holds forty. C<t/03-metadata.t> checks one of the three, by matching
C<< /(\d+) rules cover/ >>, and the claim two thousand lines earlier in
C<SKILLS.md> has said thirty-six through four rule additions.

The guard's existence is what hid it. A number nobody checks is obviously
unreliable and gets re-read; a number that is checked reads as reliable, so
nobody looks at the sentence beside it.

=head2 Why this does not simply add the second phrasing

Alternating C<rules cover> with C<rules police> would be green tomorrow and
blind to the third wording the day after - the same failure, one alternation
later. This matches the SHAPE of the claim - a number ahead of the word C<rules>,
with at most two words between them - which is what all three sentences have in common and
what a fourth would have too, and holds every one of them to what
C<policy_rules> reports. The shape was widened once already, after review
pointed out that C<40 police rules> and C<40 policy rules> went unheard; it was
measured across all 121 documents before being widened, and returns the same
three claims with no false positives.

The documents are walked rather than named, for the same reason: a count claimed
in a document nobody listed is exactly the case that produced this card.

=cut
