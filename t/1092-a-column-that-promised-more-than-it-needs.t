#!/usr/bin/env perl
# TKT-691. docs/POLICIES.md's Requires column names the flags a rule needs to
# be declared - and nothing ever checked that column against what the rule
# actually needs (%POLICY_RULES' own 'needs' list). Two rows drifted:
# agent-still's cell said `--age --notify`, though --notify is optional
# (declaring the rule without it works fine); answer-unjudged's cell said
# `--age, --read-age`, though --read-age is the same kind of optional extra.
# Verified live: `d2 tira.policy.add --rule agent-still --age 4h --action
# bridge-reminder` (no --notify) is ACCEPTED, so the Requires cell was
# claiming a flag the rule does not require at all.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Tira;

# The needs-key -> CLI-flag correspondence, read from how
# lib/Tira/CLI/Board.pm's policy-adding block actually builds %policy from
# %option: most keys become --key-with-hyphens-for-underscores directly, and
# 'before' is the one deliberate exception - spelled out as --before-column
# rather than reusing --before, which already means a date filter elsewhere.
my %FLAG_FOR = ( before => 'before-column' );

my $pod_source = do {
    open my $fh, '<', 'docs/POLICIES.md' or die "Cannot read docs/POLICIES.md: $!";
    local $/;
    <$fh>;
};

# Anchored on the Requires table specifically (the one headed '| Rule |
# Requires | Catches |'), not the single-agent/chain table earlier in the
# same file that also keys rows on rule names but never claims to be
# CLI-flag requirements.
my ($table) = $pod_source =~ /^\| Rule \| Requires \| Catches \|\n\|.*?\n(.*?)\n(?=^#)/ms;
ok( $table, 'found the Requires table to read rows from' );

my ( %documented_flags, @duplicate_rows );
while ( $table =~ /^\| `([a-z][a-z-]*)` \| (.*?) \|/mg ) {
    my ( $rule, $cell ) = ( $1, $2 );
    # A cell's flags are not each individually back-ticked - card-duration's
    # cell is one single span, `--column --age --type` - so this reads every
    # --flag-shaped token in the cell, not just ones with their own backticks.
    my @flags = $cell =~ /(--[a-z][a-z-]*)/g;
    # Codex review: silently overwriting a repeated rule name could let a
    # duplicate, malformed row hide a real mismatch depending which copy
    # won. A rule names exactly one row in this table or the table itself
    # is wrong, so a second sighting is its own failure rather than data.
    push @duplicate_rows, $rule if exists $documented_flags{$rule};
    $documented_flags{$rule} = \@flags;
}
is_deeply( \@duplicate_rows, [], 'no rule appears twice in the Requires table' );

cmp_ok( scalar keys %documented_flags, '>', 30, 'the Requires table has rules to check' );

my $specs = Tira->new->policy_rule_specs;

# Codex review: iterating only %POLICY_RULES's own keys means a row for a
# rule that no longer exists (renamed or removed) is never even looked at,
# and reporting nothing for it reads as agreement. The union of both sides
# is what actually needs comparing.
my %all_rules = ( %{$specs}, %documented_flags );
my @mismatched;
for my $rule ( sort keys %all_rules ) {
    my @needs = @{ $specs->{$rule}{needs} // [] };
    my %expected_flags = map { ( '--' . ( $FLAG_FOR{$_} // ( $_ =~ tr/_/-/r ) ) ) => 1 } @needs;
    my %documented = map { $_ => 1 } @{ $documented_flags{$rule} // [] };

    # --type is not a per-rule need at all - lib/Tira/CLI/Board.pm's own
    # policy-building code sets it unconditionally on every declaration
    # ($policy{type} = $option->{type} if defined ...), outside the
    # needs-mapped list entirely. docs/POLICIES.md's own prose calls it "the
    # same generic scope every rule shares" - so a row naming it is not
    # claiming a need this guard can check, and is not an extra either.
    delete $documented{'--type'};

    # task-card-mismatch documents --column-role as an explicit ALTERNATIVE
    # spelling of its one real need ('column' -> --column), not a second
    # need on top of it - its own row says so: "--column ... or
    # --column-role". Satisfying the need with either spelling is correct,
    # so --column-role counts toward the same expected flag rather than
    # being extra.
    if ( $documented{'--column-role'} && $expected_flags{'--column'} ) {
        delete $documented{'--column-role'};
        $documented{'--column'} = 1;
    }

    my @missing_from_doc = sort grep { !$documented{$_} } keys %expected_flags;
    my @extra_in_doc     = sort grep { !$expected_flags{$_} } keys %documented;
    next if !@missing_from_doc && !@extra_in_doc;
    push @mismatched, "$rule: missing @missing_from_doc / extra @extra_in_doc";
}

is_deeply( \@mismatched, [],
    "every rule's documented Requires cell matches its real needs, in both directions" )
  or diag( join( "\n", @mismatched ) );

done_testing;

__END__

=head1 NAME

1092-a-column-that-promised-more-than-it-needs.t - docs/POLICIES.md's Requires column matches what a rule actually needs

=head1 DESCRIPTION

TKT-691. Compares every rule's C<%POLICY_RULES> C<needs> list against
docs/POLICIES.md's own Requires column, in both directions - a documented
flag the rule does not need, and a needed flag the table omits, both fail.
C<card-stalled>'s C<before> need is checked against its real
C<--before-column> flag rather than a naive C<--before>, matching the one
place the CLI's own key-to-flag mapping renames a need.

=cut
