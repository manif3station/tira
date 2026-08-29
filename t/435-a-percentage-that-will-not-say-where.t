#!/usr/bin/env perl
# The coverage gate prints a percentage and stops.
#
#     coverage is below 100% for lib/Tira/CLI.pm: lib/Tira/CLI.pm 99.8 100.0 99.8
#
# One module, one statement missing, no line - while the Devel::Cover database
# that knows the answer sits in cover_db in the same directory and answers in a
# quarter of a second.
#
# MEASURED TWICE, A YEAR APART, AND IT COST A SESSION BOTH TIMES. The card names
# the first: CLI.pm 4503, 4619 and 4620, found after a night of guessing, and
# 4503 turned out to be unreachable by any --once test at all. The second was
# this afternoon on TKT-704 - lib/Tira.pm 99.8, and finding line 12134 took a
# throwaway text parser and two failed attempts at the column layout.
#
# THE SECOND TIME HAD A STING THE CARD DID NOT PREDICT, and it is why assertion
# ordering below puts the database first: the 99.8 was WRONG. It came from a
# prove -j 4 run, and parallel Devel::Cover loses data on merge; the same tree
# run serially reported 100.0. So a refusal that named the line would have sent
# a reader to a statement three tests demonstrably enter. Naming the line is
# still right - a reader who can open it finds out in a minute what took forty -
# but the number it hangs under is only as good as the run beneath it.
#
# WHY THIS TEST BUILDS A REAL DATABASE rather than asserting the helper's shape.
# The house pattern for tools/ is to read the source and check what it says, and
# for docs-examples-run that is right because running it needs a scratch board
# and several hundred commands. This helper needs one instrumented file and a
# quarter of a second, and its whole purpose is producing correct output from a
# database - which a shape assertion cannot check at all.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Shipped qw(runnable_ok);

my $tool = File::Spec->catfile(qw(tools coverage-holes));

runnable_ok( $tool, 'the coverage helper ships and is runnable' );

# --- a database with one statement and one subroutine deliberately missed -----
#
# Written across several lines on purpose. The obvious one-liner form puts every
# statement on line 2, so an assertion that the right LINE is named cannot fail
# for the right reason.

my $work = tempdir( CLEANUP => 1 );
my $db   = File::Spec->catdir( $work, 'cover_db' );
my $mod  = File::Spec->catfile( $work, 'Tiny.pm' );

open my $out, '>', $mod or die "$mod: $!";
print {$out} <<'MODULE';
package Tiny;

sub run {
    my ($n) = @_;
    if ( $n > 0 ) {
        return 'positive';
    }
    return 'not positive';
}

sub never_called {
    return 'nobody calls me';
}

1;
MODULE
close $out;

my $built = system(
    $^X, "-MDevel::Cover=-db,$db,-silent,1", "-I$work", '-MTiny',
    '-e', 'Tiny::run(1)'
) == 0;
plan skip_all => 'Devel::Cover is not usable here' if !$built || !-d $db;

# `run('not positive')` is never reached and `never_called` is never called, so
# the database holds exactly one uncovered statement and one uncovered
# subroutine - the two things the card asks to be named.

my $report = qx{$^X $tool --db "$db" 2>&1};

# --- it names the uncovered statement, as file and line ----------------------

like( $report, qr/Tiny\.pm/,
    'the helper names the file that has a hole' );
like( $report, qr/Tiny\.pm[: ]+8\b/,
    'and the line of the uncovered statement - "return \'not positive\'" is '
      . 'line 8, and a reader can open it' );

# --- and the uncovered subroutine, which is half the criterion ---------------
#
# Statements and subroutines are separate measures with separate thresholds, and
# a helper that reports only statements answers half the refusal.

like( $report, qr/never_called/,
    'and the subroutine nobody called, by name rather than only by line' );

# --- without naming what IS covered ------------------------------------------
#
# The control. A helper that dumps every line in the file satisfies every
# assertion above and is useless: the reader is back to reading a report to find
# the one line that matters.

# Guarded on the report being real output. Without the guard this passes
# against a helper that does not exist at all, whose error message mentions no
# line numbers - a green that means nothing.
ok( $report =~ /Tiny\.pm/ && $report !~ /\bline 6\b|:6\b/,
    'and says nothing about line 6, which is covered - a dump of every line '
      . 'would pass the assertions above and help nobody' );

# --- a module at 100% prints nothing extra -----------------------------------
#
# The card's fourth criterion, and the one that decides whether this gets left
# switched on. A passing gate that grew a paragraph is a passing gate people
# stop reading.

my $clean_db = File::Spec->catdir( $work, 'clean_db' );
system(
    $^X, "-MDevel::Cover=-db,$clean_db,-silent,1", "-I$work", '-MTiny',
    '-e', 'Tiny::run(1); Tiny::run(-1); Tiny::never_called()'
);
my $clean = qx{$^X $tool --db "$clean_db" 2>&1};
is( $clean =~ /\S/ ? 0 : 1, 1,
    'a fully covered run prints nothing at all, so a passing gate is not made '
      . 'noisier - printed: ' . ( $clean =~ s/\s+/ /gr || '(nothing)' ) );

# --- and a database it cannot read says so, rather than reporting health -----
#
# The sixth criterion, and the one with teeth: silence from a broken instrument
# is indistinguishable from silence from a clean tree. That is the same fault
# TKT-684 is open about for police.outstanding, one tool over.

my $missing = qx{$^X $tool --db "$work/not-a-database" 2>&1};
my $missing_status = $?;
like( $missing, qr/no database|cannot read|not found|unreadable/i,
    'a missing database says so plainly instead of printing nothing and '
      . 'reading as a clean gate' );
# Guarded the same way: a helper that does not exist also exits non-zero, so
# without -e the assertion is satisfied by its own absence.
ok( -e $tool && $missing_status != 0,
    'and exits non-zero, so a caller cannot mistake it for success' );

# --- and it does not answer a refusal with five thousand lines ---------------
#
# FOUND BY WIRING IT UP, not by reading the card. A partial run of one test file
# against this tree produced 5,625 uncovered lines in lib/Tira.pm alone, and a
# gate that answers a refusal with five thousand lines of stderr has replaced one
# unusable output with another.
#
# The count is the point rather than the cap. A silent truncation would be this
# card's own fault one level up: an output that looks complete and is not.

my $many_db = File::Spec->catdir( $work, 'many_db' );
{
    open my $big, '>', File::Spec->catfile( $work, 'Many.pm' ) or die $!;
    print {$big} "package Many;\n";
    print {$big} "sub s$_ { my \$x = $_; return \$x }\n" for 1 .. 40;
    print {$big} "1;\n";
    close $big;
}
system( $^X, "-MDevel::Cover=-db,$many_db,-silent,1", "-I$work", '-MMany', '-e', '1' );
my $capped = qx{$^X $tool --db "$many_db" 2>&1};
my @printed = grep {/Many\.pm/} split /\n/, $capped;
cmp_ok( scalar @printed, '<=', 20,
    'a module with dozens of holes is capped rather than dumped - '
      . scalar(@printed) . ' lines printed' );
like( $capped, qr/and \d+ more/,
    'and says how many it did not print, so the cap cannot be mistaken for the '
      . 'whole answer' );
my $everything = qx{$^X $tool --db "$many_db" --all 2>&1};
cmp_ok( scalar( grep {/Many\.pm/} split /\n/, $everything ), '>', 20,
    'while --all still prints every one, for a reader who wants them' );

# --- read from the database, not from the text report ------------------------
#
# The third criterion, and it is about method rather than output, so it is
# asserted against the source. Parsing `cover -report text` is what failed five
# times in one session and what this replaces; a helper that shells out to it
# would produce the right answer today by the wrong means and rot the same way.

# Read defensively. A missing helper must FAIL these assertions, not abort the
# file - an abort leaves every assertion after it unrun, which is how a red test
# under-reports what is missing.
my $source = '';
if ( open my $src_fh, '<', $tool ) { $source = do { local $/; <$src_fh> }; close $src_fh }

like( $source, qr/Devel::Cover::DB/,
    'the helper asks the database' );
like( $source, qr/merge_runs/,
    'and merges the runs first - without it the database reports zero files, '
      . 'which is a silent empty answer rather than an error' );
# Asserted against CODE, not prose. The first version of this matched the
# phrase "-report text" anywhere in the file and failed on the helper's own POD,
# which explains why it does NOT parse that report - a test that forbids
# describing the thing it forbids doing. POD and comments are stripped, and what
# remains is checked for an actual invocation.
my $code = $source =~ s/^__END__.*//smr;
$code =~ s/^\s*#.*$//mg;
ok( length($source) && $code !~ /`\s*cover\b|qx\{[^}]*\bcover\b|system\([^)]*\bcover\b/,
    'and never shells out to the text report it exists to replace' );

# --- one helper, not a second parser -----------------------------------------
#
# The fifth criterion. Two parsers are how two callers drift into disagreeing
# about whether a tree is clean.
#
# NARROWED SINCE THE CARD WAS FILED, and recorded on it: the pre-push hook has
# run no suite and judged no coverage since 4.62 (TKT-680), so gate-run is the
# only caller today. The assertion is therefore that gate-run USES this helper,
# not that two named callers share it.

my $gate = '';
if ( open my $gate_fh, '<', File::Spec->catfile(qw(tools gate-run)) ) {
    $gate = do { local $/; <$gate_fh> };
    close $gate_fh;
}

like( $gate, qr/coverage-holes/,
    'tools/gate-run reaches for the helper rather than growing its own parser' );
like( $gate, qr/-report\s+text|\bcover\b/,
    'while still running the coverage report that produces the percentage - '
      . 'the lines are an addition to it, not a replacement for it' );

done_testing();

__END__

=head1 NAME

t/435-a-percentage-that-will-not-say-where.t - a coverage refusal must name the
uncovered statements and subroutines, not only the percentage

=head1 DESCRIPTION

The gate prints C<lib/Tira/CLI.pm 99.8 100.0 99.8> and stops, while the
C<Devel::Cover> database that knows which statement is missing sits beside it and
answers in a quarter of a second. Finding the line has twice cost a session:
C<CLI.pm> 4503/4619/4620 after a night of guessing, and C<lib/Tira.pm:12134> this
afternoon after two failed attempts at parsing the text report's column layout.

=head2 Why this builds a real database

The house pattern for C<tools/> is to read the source and assert its shape, which
is right for a tool whose run needs a scratch board and several hundred commands.
This helper needs one instrumented file and a quarter of a second, and its
purpose is producing correct output from a database - something no shape
assertion can check.

The fixture module is written across several lines deliberately. In the obvious
one-liner form every statement lands on line 2, and an assertion that the right
line is named cannot fail for the right reason.

=head2 What is asserted against the source instead

Two things, because both are about method rather than output: that the helper
asks C<Devel::Cover::DB> and merges runs first - without C<merge_runs> the
database reports zero files, a silent empty answer rather than an error - and
that it never shells out to the text report it exists to replace.

=cut
