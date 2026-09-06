#!/usr/bin/env perl
# TKT-954. Two gate runs on the identical tree reported lib/Tira.pm at
# 99.8/100.0/99.8 and then 100.0/100.0/100.0, naming eight uncovered lines the
# card being gated had never touched. Three further runs on one unchanged tree
# then agreed exactly, at 100.0 across all 21 modules.
#
# SO THE FIGURE DOES NOT DRIFT - IT WAS LOST ONCE. That distinction decides the
# fix. A measurement that varies every run would be caught by looking at the
# number. One that goes wrong roughly once in six runs will not be, because
# five times out of six the number is right, and the run where it is wrong is
# the run that refuses a good release - or, in the direction that matters,
# could certify a tree that genuinely has a hole.
#
# WHAT MAKES IT DETECTABLE, measured in a container rather than reasoned about:
# Devel::Cover writes one entry per test process into cover_db/runs. A run of
# prove -j4 over four test files left exactly four entries there. So a
# collection is complete when that count matches the number of test files the
# harness reports, and short when a process's fragment did not survive - which
# is exactly the failure that reports executed statements as uncovered.
#
# WHY A TOOL RATHER THAN A LINE IN gate-run. tools/gate-run has no test harness
# of its own - that is TKT-716, still open, and its four refusals have never
# been watched to fire. Putting this check in gate-run alone would add a fifth
# unwatched refusal. As a tool it is driven directly here, the way t/561 drives
# tools/coverage-guard for TKT-605.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();

my $TOOL = 'tools/coverage-complete';

sub run_tool {
    my (@args) = @_;
    my $out = qx{$^X $TOOL @args 2>&1};
    return ( $? >> 8, $out // '' );
}

sub fake_db {
    my ($runs) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    my $db  = File::Spec->catdir( $dir, 'cover_db' );
    mkdir $db or die "cannot make $db: $!";
    mkdir File::Spec->catdir( $db, 'runs' ) or die $!;
    for my $i ( 1 .. $runs ) {
        my $run = File::Spec->catdir( $db, 'runs', "run-$i" );
        mkdir $run or die $!;
    }
    return $db;
}

# --- the tool exists and is runnable ---------------------------------------

ok( -f $TOOL, "$TOOL exists" )
  or BAIL_OUT("$TOOL is the deliverable of this card - the rest cannot be judged without it");
ok( -x $TOOL, 'and is executable, so the gate can call it' );

# --- a complete collection passes ------------------------------------------
#
# The common case, and the one a false refusal would make unbearable: five
# runs recorded for five test files is exactly right.

{
    my $db = fake_db(5);
    my ( $status, $out ) = run_tool( '--db', $db, '--expected', 5 );
    is( $status, 0, 'a collection with one run per test file is accepted' );
    # non-empty is the whole claim: the denial below would pass on no output.
    like( $out, qr/\S/, 'and it says something rather than passing in silence' );
    unlike( $out, qr/incomplete/i, 'and does not call a complete collection incomplete' );
}

# --- a short collection is refused, and says by how much --------------------
#
# The whole card. Three runs recorded where five files ran means two processes'
# coverage did not survive, and every statement they alone executed now reads
# as uncovered.

{
    my $db = fake_db(3);
    my ( $status, $out ) = run_tool( '--db', $db, '--expected', 5 );
    isnt( $status, 0, 'a collection missing runs is REFUSED rather than reported as a percentage' );
    like( $out, qr/\b3\b/, 'the refusal says how many runs were recorded' );
    like( $out, qr/\b5\b/, 'and how many were expected, so the gap is visible without opening the database' );
    like( $out, qr/incomplete|missing|lost/i,
        'and names the fault as an incomplete collection rather than as a coverage failure - '
          . 'the figure was never computed from all the data' );
}

# --- a database that is not there at all is refused, not treated as empty ---
#
# The same distinction TKT-949 drew on the bridge: absent and empty are
# different claims, and a coverage tool that reads a missing database as zero
# runs would refuse for the wrong reason.

{
    my $dir = tempdir( CLEANUP => 1 );
    my ( $status, $out ) = run_tool( '--db', File::Spec->catdir( $dir, 'nothing-here' ), '--expected', 5 );
    isnt( $status, 0, 'a missing database is refused' );
    # non-empty is the whole claim: a refusal that printed nothing would leave
    # the reader with an exit status and no idea which database was missing.
    like( $out, qr/\S/, 'with something to read' );
}

# --- more runs than files is not an error ----------------------------------
#
# A forked test, or a helper process that loads the module, records its own
# run. That is not a lost fragment and must not be reported as one.

{
    my $db = fake_db(7);
    my ( $status, $out ) = run_tool( '--db', $db, '--expected', 5 );
    is( $status, 0, 'more recorded runs than test files is accepted - a forked child records its own run' );
    # non-empty is the whole claim: an accepted collection still has to say the
    # counts, or a passing gate carries no record of what was measured.
    like( $out, qr/\S/, 'and it still reports what it found' );
}

# --- the gate calls it -----------------------------------------------------
#
# A tool nothing runs is a tool that proves nothing.

{
    open my $fh, '<:raw', 'tools/gate-run' or die $!;
    my $gate = do { local $/; <$fh> };
    close $fh;
    # non-empty is the whole claim: the check below would pass on an
    # unreadable file's emptiness alone.
    like( $gate, qr/\S/, 'the gate script is there to be read' );
    like( $gate, qr/coverage-complete/,
        'the gate runs the completeness check, so an incomplete collection cannot be reported as a percentage' );
}

done_testing();

__END__

=head1 NAME

572-a-coverage-figure-from-an-incomplete-run.t - the gate refuses a coverage figure computed from incomplete data

=head1 DESCRIPTION

TKT-954. The release gate reported C<lib/Tira.pm> at 99.8% and then 100.0% for
the identical tree, naming eight lines the card had never touched; three
further runs on one unchanged tree agreed exactly. So the figure does not
drift - it was lost once, roughly one run in six, which is the kind of fault
looking at the number cannot catch.

Devel::Cover writes one entry per test process into C<cover_db/runs>, so a
collection is complete when that count matches the number of test files the
harness ran. C<tools/coverage-complete> makes that comparison and refuses a
short one with both numbers named, and the gate calls it before it reports any
percentage.

=cut
