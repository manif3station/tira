#!/usr/bin/env perl
# A test that opens a source file by name is asserting where code lives.
#
# It never says so. It claims to check that two priority tables agree, or that
# a rule names what answers it, or that a column knows where it sits - and it
# quietly also requires that the code implementing any of those has not moved.
# So it breaks on a refactor that broke nothing, and the reading is always
# "the change is wrong" before anyone checks that the test was.
#
# THIS HAS HAPPENED SEVEN TIMES IN THIS REPOSITORY. MISTAKE.md records four
# under THE-DESCRIPTION-NOT-THE-CODE - t/64, t/144, t/244 and t/289, all four
# broken by TKT-607's split, and in every case the test was the thing that was
# wrong. Then TKT-703 moved the dashboard scripts and broke t/177, which was
# "fixed" by naming a SECOND location instead of by walking - so TKT-834 moved
# the renderers and broke it again, in the same line, for the same reason.
# That is the whole argument for a guard: the fix keeps being applied to the
# instance rather than to the class.
#
# The prevention rule the fourth occurrence earned, quoted from MISTAKE.md:
# "a test must find code by walking lib/, never by naming a file - the same
# lesson TKT-594 taught the coverage gate, which arrived three more times
# unprompted."
#
# WRITTEN RED, on TKT-835, ahead of converting the nine files that still do
# it. It names them rather than counting them, so a failure says which file to
# open - the same reason t/431 asserts once per module instead of once overall.
#
# WHAT IS REFUSED IS NARROWER THAN "NAMES A MODULE", and the narrowing was
# forced by evidence rather than chosen. Reading a source file under lib/ by
# name is refused; a test that reads one because its claim is ABOUT that file
# says so on the line and is left alone - t/430 reads lib/Tira/CLI.pm precisely
# to assert the index is smaller than the modules it indexes, and t/402 reads
# DashboardWeb.pm for its own @PROVIDERS block.
#
# THE EXEMPTION IS BY MECHANISM, NOT BY A LIST OF NAMES. A list of allowed
# filenames would be maintained by exactly the discipline that let seven of
# these through.
#
# WIDENED ON TKT-921, AND THE NARROW VERSION WAS RIGHT WHEN IT WAS WRITTEN.
# Until 5.52 this refused lib/Tira.pm alone, because that is the file TKT-746
# is decomposing and TKT-835 converted exactly the files that read it. The
# eighth occurrence came from somewhere else: TKT-920 lifted the monitor
# lifecycle out of lib/Tira/CLI/Job.pm and t/516 failed three assertions
# reporting a shell loop that had moved twenty lines into another file. The
# rule was never about which file was mobile - every file is mobile, and this
# repository lifts one most weeks - so the scope is now every source file
# under lib/, .pm and view alike.
#
# MEASURED WHEN THE SCOPE CHANGED: 36 (file, path) pairs across 28 files, and
# SEVEN of those files were written the same day this widening was, hours
# after the card describing the fault was filed. That is the argument for the
# guard being wide rather than for another sweep.

use strict;
use warnings;

use File::Find ();
use Test::More;

my @tests;
File::Find::find(
    { no_chdir => 1, wanted => sub { push @tests, $File::Find::name if /\.t\z/ } },
    't' );
@tests = sort @tests;

cmp_ok( scalar @tests, '>=', 400,
    't/ was walked - ' . scalar(@tests) . ' test files' );

# READS lib/Tira.pm. Not "names a module" and not "opens a module": FOUR
# predicates were tried and the first three were each wrong in a different
# way, which is why the surviving one is written out rather than assumed.
#
#   1. opens any lib/*.pm     - too narrow. Missed t/280, which reads through
#                               a slurp() helper. Reported 12.
#
#   2. names any lib/*.pm     - too WIDE, and the important failure. Reported
#                               21 and would have forced incorrect changes on
#                               tests whose claim is ABOUT a named file:
#                               t/430 reads lib/Tira/CLI.pm precisely to
#                               assert the index is smaller than the modules
#                               it indexes, and t/402 reads DashboardWeb.pm
#                               for its own @PROVIDERS block. It also caught
#                               t/279, which opens those paths with '>' to
#                               WRITE fixture modules into a temp repo.
#
#   3. reads lib/Tira.pm,     - right rule, wrong granularity. Skipping any
#      file-level write skip     file containing a write-open anywhere in it
#                               silently dropped t/126, a genuine offender
#                               that also writes a fixture elsewhere. An
#                               exclusion coarser than the thing it excludes
#                               hides what it was meant to let through.
#
#   4. reads lib/Tira.pm,     - what is here. Reports 9, matching TKT-835's
#      per-occurrence            scope exactly, with every scope_out silent.
#
# The line that holds: lib/Tira.pm is the file TKT-746 is decomposing, so
# anything read out of it is liable to move by definition - which is exactly
# what happened to t/177 on TKT-834. A stable concern module is a legitimate
# subject for a test to be about. So: reading the engine is refused, reading
# a concern module is not, and writing is not reading.
#
# The read forms are each named rather than approximated. The loose version -
# any \w+ followed by '(' - matched `for my $module (` and reported the
# fixture writer as a reader. A predicate that catches the thing it is named
# for and one other thing is not a predicate.
# THE PATH IS ANY SOURCE FILE UNDER lib/, since TKT-921. It was lib/Tira\.pm
# alone; the capture is now the whole path so a failure names what was opened,
# and the extensions are listed rather than left open because lib/ also holds
# things a test may legitimately point at as DELIVERABLES rather than read as
# code.
my $READS_THE_ENGINE = qr{
    (?:
        open [^;\n]* ['"] < [^;\n]* ['"] \s* ,? \s*   # open my $fh, '<', ...
      | open \s+ \w+ [^;\n]*? ,? \s*                   # or the two-arg form
      | (?: slurp | read_file ) \s* \( \s*             # a named read helper
      | = \s*                                          # or bound to a variable first
    )
    ['"] (lib/ [^'"\s]+ \. (?: pm | js | css ) ) ['"]
}x;

# The write form, excluded explicitly rather than by hoping the pattern above
# misses it: t/279 builds fake modules in a temp repo and must stay untouched.
my $WRITES_IT = qr{ open [^;\n]* ['"] > ['"] }x;

# The one legitimate reason to read lib/Tira.pm by name: the claim is about
# THAT FILE rather than about code that happens to sit in it. t/426 asserts
# lib/Tira.pm itself carries no page markup - true of the engine module and
# false of lib/Tira/DashboardWeb.pm, which is the View and carries it by
# design. t/344 takes only Tira.pm's POD, which is deliberately where the
# lifted modules' methods stay documented.
#
# Marked on the line above, by somebody who wrote down why - the same
# mechanism t/176 uses for its own exception, and for the same reason: a
# check whose exception is a list of filenames is one that gets widened
# quietly, while one that costs a sentence is one somebody has thought about.
my $MARKER = 't/486 marker: about this file, not its code';

my %offender;
my $marked = 0;
for my $test (@tests) {
    open my $fh, '<:raw', $test or die "$test: $!";
    my $body = do { local $/; <$fh> };
    close $fh;

    # This file quotes the pattern it hunts for, and the first draft reported
    # itself. The same trap t/149 and t/176 both mark against.
    next if $test =~ /486-a-test-that-says-where-code-lives/;

    # Line by line, because the write exclusion has to apply to the
    # OCCURRENCE and not to the file. The first version skipped any file
    # containing a write-open anywhere in it, which silently dropped t/126 -
    # a genuine offender that also happens to write a fixture elsewhere. An
    # exclusion coarser than the thing it excludes hides what it was meant
    # to let through.
    my @lines = split /\n/, $body;
    for my $i ( 0 .. $#lines ) {
        my $line = $lines[$i];
        next if $line =~ /\A\s*#/;      # prose about the fault is not the fault
        next if $line =~ /$WRITES_IT/;   # building a fixture module is not reading one
        next if $line !~ /$READS_THE_ENGINE/;

        # The marker may sit on the line or in the comment block above it,
        # because a reason worth writing rarely fits on the end of an open().
        my $context = join "\n", @lines[ ( $i >= 6 ? $i - 6 : 0 ) .. $i ];
        if ( index( $context, $MARKER ) >= 0 ) { $marked++; next }

        push @{ $offender{$test} }, $1;
    }
}

my @named = sort keys %offender;
is_deeply( \@named, [],
    'no test reads a file under lib/ by name to find code - '
      . ( @named ? join( '; ', map { "$_ opens " . join( ', ', @{ $offender{$_} } ) } @named ) : 'none' ) );

# And the walkers are still walking, so this file cannot be satisfied by
# deleting the checks it protects.
my $walkers = 0;
for my $test (@tests) {
    open my $fh, '<:raw', $test or die "$test: $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    $walkers++ if $body =~ /File::Find/ && $body =~ /'lib'/;
}
cmp_ok( $marked, '>=', 1,
    "and the deliberate exceptions say why on the line - $marked of them" );

cmp_ok( $walkers, '>=', 3,
    "and the files that need engine source walk lib/ for it - $walkers of them" );

done_testing();

__END__

=head1 NAME

t/486-a-test-that-says-where-code-lives.t - no test may find engine code by naming a module file

=head1 DESCRIPTION

A test that opens C<lib/Tira.pm> by name asserts where code lives while
claiming to assert something else, so it breaks on a refactor that broke
nothing. It has happened seven times here: four caught by TKT-607
(F<t/64>, F<t/144>, F<t/244>, F<t/289>), then F<t/177> twice - once on
TKT-703, which patched it by naming a second file, and again on TKT-834,
which is what finally made the class worth guarding rather than the
instance worth fixing.

Refuses B<reading> C<lib/Tira.pm> by name from any file under F<t/>, and
separately asserts that the files which do need engine source are still
walking C<lib/> for it - so this cannot be satisfied by deleting the checks it
protects.

The rule is deliberately narrower than "no test may name a module". Four
predicates were tried: "opens any C<lib/*.pm>" missed the C<slurp> form;
"names any C<lib/*.pm>" was too wide and would have forced wrong changes on
tests whose claim is about a specific file, and also caught F<t/279>, which
B<writes> fixture modules rather than reading engine source. What survives is
C<lib/Tira.pm> specifically, because that is the file being decomposed.

The exemption is by mechanism rather than by a list of allowed filenames,
because a list is maintained by exactly the discipline that let seven
instances through.

=cut
