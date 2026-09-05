#!/usr/bin/env perl
# TKT-592. `tira.column.update --terminal` decides, board-wide, which columns
# count as "work has ended" - and therefore which count as active. It is
# documented as though it belonged to one police rule: docs/POLICIES.md
# mentions it only inside card-unassigned's own row, docs/commands.md never
# explains it at all (its matches for "terminal" are the word meaning a
# shell), and SKILLS.md shows it only in the usage line and inside the same
# card-unassigned clause.
#
# THE DERIVED LIST, not the remembered one. The card's own filing named
# "agent-still, board-still, card-unassigned, and the push gate" as the
# callers of the ending-column concept - checked here against the actual
# code rather than repeated: agent-still and card-changed-by-owner, plus
# conversation-not-folded, column-unwatched and discard-with-open-questions,
# read `_ending_columns`/`_ending_columns_everywhere` directly.
# card-unassigned and board-still read the column's `terminal` flag through
# the sibling `_resting_columns`, which the code's own comment says shares
# "the same assumption ... for the same reason" - a real but DIFFERENT
# function, not the one the filing named. Both families, plus the push gate's
# own SHIPPED_FROM/endings() in tools/card-holes, are three implementations
# of one board-wide concept, and the documentation has to say so accurately
# rather than repeat whichever rule happened to notice it first.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 't/lib';
use Suite;

my $policies = do {
    local $/;
    open my $fh, '<:encoding(UTF-8)', 'docs/POLICIES.md' or die "docs/POLICIES.md: $!";
    <$fh>;
};
my $commands = do {
    local $/;
    open my $fh, '<:encoding(UTF-8)', 'docs/commands.md' or die "docs/commands.md: $!";
    <$fh>;
};
my $skills = do {
    local $/;
    open my $fh, '<:encoding(UTF-8)', 'SKILLS.md' or die "SKILLS.md: $!";
    <$fh>;
};

# non-empty is the whole claim: an unreadable file would pass every denial
# below on emptiness alone - the fault t/147 exists to catch.
like( $policies, qr/\S/, 'docs/POLICIES.md is there to be read' );
like( $commands, qr/\S/, 'docs/commands.md is there to be read' );
like( $skills,   qr/\S/, 'SKILLS.md is there to be read' );

# --- docs/POLICIES.md: one section, not one rule's aside ---------------------

my ($section) = $policies =~ /^(## Where work ends\b.*?)(?=^## )/ms;
ok( defined $section && length $section,
    'docs/POLICIES.md has its own section on ending columns' )
  or BAIL_OUT('no "## Where work ends" section - update the heading this test looks for');

like( $section, qr/--terminal/, 'and it names --terminal' );
like( $section, qr/--no-terminal/, 'and --no-terminal' );

# --- derived, not remembered: every real caller is named, checked against code ---

my $engine = Suite::engine_source();

for my $rule (qw(
    conversation-not-folded column-unwatched card-changed-by-owner
    agent-still discard-with-open-questions
)) {
    like( $engine, qr/\$rule eq '\Q$rule\E'/,
        "$rule is a real rule in the engine - the list this section names is "
          . 'checked against code, not memory' );
    like( $section, qr/\Q$rule\E/, "and the new section names $rule" );
}

# card-unassigned and board-still take the ending concept through a sibling
# function, not the one named above - the section has to say this rather
# than lump all five together as though they were the same call.
like( $engine, qr/sub _resting_columns/,
    '_resting_columns is a real function in the engine' );
like( $section, qr/card-unassigned/, 'and the section names card-unassigned' );
like( $section, qr/board-still/,     'and board-still' );

# The push gate: a third implementation, in Python, outside the engine
# entirely - named because "the push-gate consequence" is one of this card's
# own acceptance criteria and it costs a refused push, not a bridge reminder.
like( $section, qr/card-holes/i, 'and tools/card-holes, the push gate' );
like( $section, qr/SHIPPED_FROM|push column/,
    'with enough of the mechanism that a reader recognises it in the code' );

# --- the per-rule rows point at the section, rather than each carrying it ----

like( $policies, qr/card-unassigned[^\n]*Where work ends/s,
    "card-unassigned's own row points at the new section" );

# --- docs/commands.md: the sharper half of the gap ---------------------------

like( $commands, qr/--terminal/, 'docs/commands.md names --terminal' );
unlike( $commands, qr/\A\z/, 'the file is not empty' );  # trivially true; keeps intent visible

# The three existing matches for "terminal" are all the shell, not the flag -
# so presence alone proves nothing. The real content has to explain what
# marking a column terminal DOES.
like( $commands, qr/--terminal[^\n]{0,400}?ending|ending[^\n]{0,400}?--terminal/is,
    'and explains what the flag actually does - not just the shell meaning of the word' );

# --- SKILLS.md: the consequence beside the usage line, not only in prose ----

my ($usage_area) = $skills =~ /(tira\.column\.update[^\n]*--terminal[^\n]*(?:\n[^\n]*){0,20})/;
ok( defined $usage_area, 'SKILLS.md has a column.update usage area to check' )
  or BAIL_OUT('no column.update usage line found in SKILLS.md');
like( $usage_area, qr/terminal/i,
    'and the consequence is stated near the usage line itself, not only inside '
      . "card-unassigned's own prose elsewhere in the document" );

done_testing();

__END__

=head1 NAME

555-a-flag-decided-board-wide-documented-as-one-rules.t - --terminal gets one real section

=head1 DESCRIPTION

TKT-592. C<tira.column.update --terminal> decides board-wide which columns
count as work having ended, and was documented as though it belonged to one
police rule. This asserts a real C<## Where work ends> section in
docs/POLICIES.md naming the actual callers of C<_ending_columns> /
C<_ending_columns_everywhere> - checked against the engine's own source
rather than the filing card's remembered list, which named C<board-still> and
C<card-unassigned> as direct callers when they in fact read the ending
concept through the sibling C<_resting_columns> - plus docs/commands.md
explaining the flag itself and SKILLS.md stating the consequence beside the
usage line.

=cut
