#!/usr/bin/env perl

# TKT-736. t/433 holds every claim of the police rule count to what the
# engine reports, but only in markdown - found stale, live, by TKT-704's
# own REQ-027 check (grepping for surviving "36 rules" after the
# documentation was corrected), because two claims live in Perl source
# and nothing walks there:
#
#   lib/Tira/DashboardWeb.pm   a # comment giving the police engine's
#                              size as a parenthetical aside
#   t/378 (a test file)       the same aside, in its own POD instead
#
# SCOPE, narrower than t/433's own shape, and deliberately so. t/433's
# shape ("N + <=2 words> + rules + <=1 word>") is safe across markdown
# because documentation states the total count as its own sentence.
# Checked directly before choosing a shape here: that same wide shape
# against every .pm/.t line comment and POD block in this repository also
# matches "27 rules stopped at the first bad byte" (an incident count),
# "26 rules, neither of them listed" (a worked example), "35 existing
# policy rules asked whether..." (another card's own historical problem
# statement) and "21 rules declare a required parameter" (a subset
# property) - four real sentences, none of them a claim of the engine's
# total rule count, all matched by the wide shape anyway. Source
# comments narrate debugging history far more than documentation does,
# and "N rules" turns out to describe many different things there.
#
# WHAT DOES NOT FALSE-POSITIVE: both real target claims - and neither of
# the four sentences above - use a bare parenthetical aside, "(N
# rules)". That shape is what this guard matches, on purpose narrower
# than t/433's, because it is the one shape actually used for this claim
# in source and the only one checked clean against the false positives
# above.
#
# THE OTHER HALF: t/433 itself quotes the stale wording, in its own
# explanatory comments, several times - "36 rules police" among them,
# describing what went wrong rather than asserting it now. None of
# t/433's own quotes use the bare parenthetical shape this guard matches,
# so they would already miss on shape alone; the quote-stripping is
# still exercised directly (see the fixture below), since a future claim
# quoted IN that exact "(N rules)" shape must not become a false
# positive either. A quoted span, even one that runs across several
# comment lines (as one of t/433's own does), is stripped before
# matching - comment and POD lines are joined into blocks first, the
# same way a markdown paragraph is, so the closing quote need not land
# on the same line as the opening one. DOUBLE QUOTES ONLY - every real
# quoted claim in this codebase's history uses "...", and a single-quote
# span was tried and reverted after a plain contraction or possessive
# ("today's ... the board's own list") stripped a real claim sitting
# between its two apostrophes, found by Codex review reproducing it
# directly (see the fixture below). The replacement keeps the stripped
# span's original length rather than collapsing it to one space, so a
# match position found after stripping still lands on the same offset
# the per-line table was built against - collapsing it was the first
# version, and it mis-attributed a real claim to the wrong line whenever
# an earlier line in the same block held a quote of a different length.
#
# HEREDOC BODIES ARE NEVER READ AS PROSE: a heredoc's own lines are
# neither # comment lines nor POD, but a line inside one CAN start with
# # (this test's own fixture below does, deliberately, to look like
# realistic Perl source) - so the delimiter itself is tracked and every
# line up to and including the closing delimiter is skipped outright,
# rather than relying on the line shape alone to keep it out. Only a
# line of actual code can OPEN a heredoc, never a comment or POD line -
# checked before this line reaches the # extraction below, since a
# sentence merely naming the syntax ("Example syntax: <<END") is not an
# opener and reading it as one swallows every real line after it, which
# Codex review also reproduced directly. <<~ is Perl's own indented
# form and its closing line is allowed to share the body's indentation,
# so the terminator match allows leading whitespace only for that form -
# a plain << terminator still has to start at column 0, same as Perl
# itself requires.
#
# WRITTEN RED: DashboardWeb.pm and t/378 both currently say 36 while the
# engine ships 49.

use strict;
use warnings;

use File::Find ();
use Test::More;

use lib 'lib';
use Tira;

my $rules = Tira->new->policy_rules;
cmp_ok( scalar @{$rules}, '>=', 30,
    'the engine reports its rules - ' . scalar( @{$rules} ) . ' of them' );

# --- what counts as a claim in Perl source -----------------------------------

sub _claims_in_source {
    my ($text) = @_;
    my ( @claims, $in_pod, @block, @block_lines );

    my $flush = sub {
        return if !@block;
        my $joined = join ' ', @block;

        # DOUBLE QUOTES ONLY. Every real quoted claim in this codebase's own
        # history (t/433's, this file's own) uses "..." - never '...'. A
        # single-quote span was tried and reverted: a sentence with a claim
        # sitting between two apostrophes used for a contraction and a
        # possessive - "today's ... the board's own list" - had the whole
        # span between them read as one quoted string and stripped, eating a
        # live claim entirely; Codex review reproduced it (see the fixture
        # below). Same-length replacement (not a single space) so a match
        # position found in $stripped still lands on the same character
        # offset $line_for was built against.
        ( my $stripped = $joined ) =~ s/("[^"]*")/q{ } x length($1)/ge;

        my @offsets;
        my $running = 0;
        for my $i ( 0 .. $#block ) {
            push @offsets, $running;
            $running += length( $block[$i] ) + 1;
        }
        my $line_for = sub {
            my ($offset) = @_;
            my $line = $block_lines[0];
            for my $i ( 0 .. $#offsets ) {
                $line = $block_lines[$i] if $offsets[$i] <= $offset;
            }
            return $line;
        };

        while ( $stripped =~ /\(\s*(\d+)\s+rules\s*\)/g ) {
            my $match_start = pos($stripped) - length($&);
            push @claims, { line => $line_for->($match_start), claimed => $1 };
        }
        @block       = ();
        @block_lines = ();
    };

    my ( $heredoc_end, $heredoc_indented );
    my $line_number = 0;
    for my $line ( split /\n/, $text, -1 ) {
        $line_number++;

        # A heredoc body can contain lines that themselves start with #
        # (this very test's own fixture does, deliberately, to look like
        # realistic Perl source) - those are not comments, and must not
        # reach the prose extraction below at all.
        if ( defined $heredoc_end ) {
            my $matched =
              $heredoc_indented
              ? ( $line =~ /^\s*\Q$heredoc_end\E\s*\z/ )
              : ( $line eq $heredoc_end );
            undef $heredoc_end if $matched;
            next;
        }

        # ONLY A LINE OF REAL CODE CAN OPEN A HEREDOC - never a # comment or
        # POD line describing one. Checked before this line is classified as
        # prose below, otherwise a sentence that merely MENTIONS the syntax
        # ("# Example syntax: <<END") reads as an opener and swallows every
        # line after it as heredoc body - Codex review reproduced exactly
        # that with a real comment. <<~ marks an indented terminator (Perl
        # allows the closing line to share the heredoc body's own
        # indentation); a plain << terminator must still start at column 0.
        if ( !$in_pod
            && $line !~ /^\s*#/
            && $line =~ /<<(~?)\s*["']?(\w+)["']?/ )
        {
            $heredoc_end       = $2;
            $heredoc_indented  = ( $1 eq '~' );
        }

        if ( $line =~ /^=(\w+)/ ) {
            $flush->();
            $in_pod = ( $1 ne 'cut' );
            next;
        }
        my $prose;
        if ($in_pod)                     { $prose = $line }
        elsif ( $line =~ /^\s*#\s?(.*)/ ) { $prose = $1 }
        if ( !defined $prose ) { $flush->(); next }
        push @block,       $prose;
        push @block_lines, $line_number;
    }
    $flush->();
    return \@claims;
}

# --- the control: a live comment claim, a quoted record spanning two lines --
# in a comment, a live POD claim, and a heredoc that must be invisible -------
# entirely, plus a shape this guard deliberately does not treat as a claim --

my $fixture = <<'PERLSOURCE';
# The board-wide police policy engine (40 rules), separate from a
# column's own required-action template.
# It once said "(36
# rules)" before the fix landed - a quote spanning two lines.

=head1 DESCRIPTION

This module serves the same engine (40 rules), described here too.

=cut

# Twenty-seven rules stopped at the first bad byte - an incident count,
# not a claim of the engine's total, and not parenthetical either.
my $sample = <<'HEREDOC';
police policy engine (36 rules)   # this line must never be read as prose
HEREDOC
PERLSOURCE

my $fixture_claims = _claims_in_source($fixture);
is_deeply(
    [ map { $_->{claimed} } @{$fixture_claims} ],
    [ '40', '40' ],
    'the live comment claim and the live POD claim are both found, both say '
      . '40 - the quoted record spanning two comment lines is not a claim, '
      . 'the incident-count sentence with no parentheses is not a claim, and '
      . 'the heredoc body is never read as prose at all' );

# --- the four defects Codex review found by reproducing each one directly ---
# against a hand-written case, rather than trusting the first fixture alone
# to have covered them.

# (1) An apostrophe used for a contraction or possessive is not a quote. The
# first version stripped '[^']*' the same as "[^"]*", and "Today's ... the
# board's authoritative list" has two apostrophes with a real claim between
# them - stripped as if it were quoted text, eating a live claim entirely.
my $contraction_claims = _claims_in_source(
    "# Today's policy engine (49 rules) is the board's authoritative list.\n"
);
is_deeply( [ map { $_->{claimed} } @{$contraction_claims} ], ['49'],
    "an apostrophe in a contraction or possessive is not read as a quote - "
      . "the claim between two of them still counts" );

# (2) <<~ is Perl's INDENTED heredoc - its own closing line is allowed to
# share the body's indentation, so a bare `eq` against the bareword alone
# never matches an indented terminator and the heredoc, wrongly, never ends.
my $indented_heredoc_claims = _claims_in_source(<<'INDENTED');
my $x = <<~END;
    prose inside, never read
    END
# the engine now ships (49 rules)
INDENTED
is_deeply( [ map { $_->{claimed} } @{$indented_heredoc_claims} ], ['49'],
    'an indented <<~ terminator still closes the heredoc, so the real claim '
      . 'after it is read rather than swallowed as heredoc body forever' );

# (3) A comment that merely MENTIONS heredoc syntax is not an opener. Only a
# line of actual code can start one - a sentence like "Example syntax: <<END"
# is prose, and reading it as an opener swallows every real line after it.
my $mentioned_heredoc_claims = _claims_in_source(
    "# Example syntax: <<END\n# the engine ships (49 rules)\n" );
is_deeply( [ map { $_->{claimed} } @{$mentioned_heredoc_claims} ], ['49'],
    'a comment merely naming heredoc syntax does not open one, so the real '
      . 'claim on the very next comment line is still read' );

# (4) A quoted span on an EARLIER line in the same block shortens $stripped
# relative to the unstripped @block the offset table was built from - unless
# the replacement keeps the same length, every offset after it points at the
# wrong line. Two lines, a quote on the first, a real claim on the second.
my $line_map_claims = _claims_in_source(
    qq{# historical "(36 rules)" is what it used to say\n# live (49 rules)\n} );
is_deeply( [ map { "$_->{claimed}\@$_->{line}" } @{$line_map_claims} ],
    ['49@2'],
    'the claim is attributed to its own real line even though an earlier '
      . 'quoted span in the same block is a different length once stripped' );

# --- every Perl source file that might carry a live claim -------------------

my @sources;
File::Find::find(
    { no_chdir => 1, wanted => sub { push @sources, $File::Find::name if /\.(?:pm|t)\z/ } },
    'lib', 't', 'cli' );
cmp_ok( scalar @sources, '>=', 10, 'the source tree was walked - ' . scalar(@sources) . ' files' );

my @claims;
for my $source ( sort @sources ) {
    open my $fh, '<', $source or die "$source: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    push @claims, map { { %{$_}, in => $source } } @{ _claims_in_source($text) };
}

cmp_ok( scalar @claims, '>=', 2,
    'source claims the rule count somewhere - '
      . join( ', ', map { "$_->{in}:$_->{line} says $_->{claimed}" } @claims ) );

ok( ( grep { $_->{in} =~ m{DashboardWeb\.pm\z} } @claims ),
    'lib/Tira/DashboardWeb.pm contributes a claim - the one this ticket was found from' );
ok( ( grep { $_->{in} =~ m{378-the-police-policies-modal\.t\z} } @claims ),
    't/378 contributes a claim too - the one living in POD rather than a comment' );

# t/433 quotes the same stale wording in its own comments, to explain the
# history this ticket continues - it must never appear here.
ok( !( grep { $_->{in} =~ m{433-a-count-stated-three-times-and-checked-once\.t\z} } @claims ),
    "t/433's own quoted historical comments are correctly not read as live claims" );

# The four real sentences found while designing this guard's own shape -
# an incident count, a worked example, another card's historical problem
# statement, and a subset property - none of them a claim of the total.
for my $false_positive (
    qw(170-a-board-that-could-not-be-read.t 174-a-rule-you-cannot-put-down.t
       383-a-handle-nobody-wrote-down.t 79-policy.t) )
{
    ok( !( grep { $_->{in} =~ /\Q$false_positive\E\z/ } @claims ),
        "t/${false_positive}'s own unrelated 'N rules' sentence is correctly not a claim" );
}

for my $claim (@claims) {
    is( $claim->{claimed}, scalar @{$rules},
        "$claim->{in}:$claim->{line} - '($claim->{claimed} rules)' matches what the engine reports" );
}

done_testing;

__END__

=head1 NAME

1099-a-count-that-quoted-its-own-history.t - every "(N rules)" claim in Perl source matches the engine

=head1 DESCRIPTION

TKT-736. t/433 held every markdown claim of the police rule count to
C<policy_rules()>; two live claims in Perl source (a comment in
C<lib/Tira/DashboardWeb.pm>, POD in C<t/378-the-police-policies-modal.t>)
went unchecked and drifted to 36 while the engine grew to 49. Scoped
narrower than t/433's own shape - a bare parenthetical C<(N rules)> -
because the wider shape, checked directly against this repository's own
source comments, matches several real sentences that are not claims of
the total at all (an incident count, a worked example, another card's
own historical problem statement, a subset property). Comment and POD
lines are joined into blocks before a quoted span is stripped, so a
quote spanning several comment lines - as one of t/433's own does - is
still recognised as a quote. Code and heredoc bodies are never read as
prose at all.

=cut
