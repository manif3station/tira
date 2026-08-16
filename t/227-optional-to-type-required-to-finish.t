#!/usr/bin/env perl
# What the manual calls optional, the gate calls mandatory.
#
# SKILLS.md is the first thing an agent reads, and its record field table marks
# --problem, --solution-needed, --deliverable, --acceptance, --test-step, --bdd
# and --atdd optional. The push gate refuses while a live card is missing any
# of them, and police says the same thing now that both read one definition.
#
# Both are right about different things and the table said so about neither.
# Create and Update describe what the command needs; a card can be made with a
# title alone and cannot be finished with one. An agent that fills in what says
# required produces cards that are refused later, and learns it by having a
# release blocked: five such cards did exactly that on 2026-08-15, after the
# suite and the coverage had already passed.
#
# Asserted against the definition rather than against a list written here, so
# the manual cannot drift from what the gate enforces without this failing.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Tira;

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

my $manual = slurp('SKILLS.md');

# --- the table says which of its two questions it is answering --------------

like( $manual, qr/what the command needs, not what a card needs/,
    'the manual says its table is about the command rather than about the card' );
like( $manual, qr/tira\.card\.required/,
    'and points at the one definition of what a card needs' );

# --- and the fields it marks optional are in that definition ----------------
#
# Read from the engine, not listed here. A test with its own list would be a
# fourth place for this to drift, which is the fault it is guarding against.

my %required = map { $_ => 1 } @{ Tira->card_required };
my %argument = (
    '--problem'          => 'problem_or_feature',
    '--solution-needed'  => 'solution_needed',
    '--deliverable'      => 'deliverables',
    '--acceptance'       => 'acceptance_criteria',
    '--test-step'        => 'test_steps',
    '--bdd'              => 'bdd',
    '--atdd'             => 'atdd',
);

for my $argument ( sort keys %argument ) {
    my $field = $argument{$argument};
    next if !$required{$field};

    my ($row) = $manual =~ /^\|\s*`\Q$argument\E[^|]*\|([^\n]*)$/m;
    ok( defined $row, "the manual has a row for $argument" );
    like( $row // '', qr/optional/,
        "$argument is optional to type, which is what that column means" );
}

done_testing;

__END__

=head1 NAME

227-optional-to-type-required-to-finish.t - two questions, one column

=head1 DESCRIPTION

The manual's field table marks fields optional and the push gate refuses cards
that lack them. Both are right: the columns say what the command needs, and a
card can be created with a title alone but not finished with one.

The table now says which question it is answering and points at the definition
of the other. The fields are read from that definition rather than listed here,
so a test cannot become a fourth place for this to drift.

=cut
