#!/usr/bin/env perl
# TKT-683. tools/gate-run ran the suite under Devel::Cover serially, taking
# roughly twice as long as it needed to on a multi-core machine. Two earlier
# attempts at -j were reverted: the first wrongly blamed Devel::Cover's
# shared cover_db for a set of spurious "exit 25 / No plan found" failures
# that turned out (CMT-003 on this card) to be an unrelated fixture bug
# (TKT-668's status validation refusing 12 fixtures' stale 'todo'/'Open'
# literals), never isolated with a clean serial baseline first. That baseline
# now genuinely exists - the full suite has run serially, clean, many times
# since - so this re-attempt adds -j with the worker count derived from the
# machine, leaving at least one core free, rather than hard-coded.

use strict;
use warnings;

use File::Spec;
use Test::More;

my $root = File::Spec->rel2abs('.');
my $path = File::Spec->catfile( $root, 'tools', 'gate-run' );

my $source = do {
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    <$fh>;
};

# --- the source derives JOBS from the machine, not a hard-coded number ------

like( $source, qr/CORES=\$\(nproc\)/,
    'the worker count starts from the machine\'s own core count' );
like( $source, qr/JOBS=\$\(\(\s*CORES\s*>\s*1\s*\?\s*CORES\s*-\s*1\s*:\s*1\s*\)\)/,
    'and leaves at least one core free, using arithmetic rather than a '
      . 'conditional command whose own false exit would abort the '
      . '&&-chained script around it - the exact shape of bug the earlier '
      . 'reverted attempt would have hit if CORES had ever been 1' );
like( $source, qr/prove\s+-j"\$JOBS"\s+-lr\s+t\b/,
    'prove is actually told to use that many workers' );

# --- the formula itself, exercised directly rather than trusted from source -

my ($formula) = $source =~ /(JOBS=\$\(\(\s*CORES\s*>\s*1\s*\?\s*CORES\s*-\s*1\s*:\s*1\s*\)\))/;
ok( $formula, 'the JOBS formula was found in the source to run it for real' );

for my $case ( [ 1 => 1 ], [ 2 => 1 ], [ 4 => 3 ], [ 8 => 7 ], [ 16 => 15 ] ) {
    my ( $cores, $want ) = @{$case};
    my $got = `CORES=$cores bash -c '$formula; echo \$JOBS'`;
    chomp $got;
    is( $got, $want, "with $cores core(s) reported, JOBS becomes $want" );
}

done_testing();

__END__

=head1 NAME

t/467-a-worker-count-that-fits-the-machine.t - tools/gate-run's -j worker
count adapts to the machine, leaving one core free

=head1 DESCRIPTION

TKT-683. Two earlier attempts to parallelize C<tools/gate-run>'s coverage
run were reverted, both for the wrong reason at first: a set of spurious
test failures under C<-j> was blamed on C<Devel::Cover>'s shared
C<cover_db>, then later found (in the same card's own history) to be an
unrelated pre-existing fixture bug that would have failed serially too, had
a clean baseline been checked first. This attempt derives the worker count
from C<nproc>, leaving at least one core free, using pure arithmetic rather
than a conditional command - the earlier draft's C<[ "$JOBS" -gt 1 ] &&
JOBS=...> pattern would itself abort the surrounding C<&&>-chained script on
a single-core machine, since a false test's exit status propagates through
the chain.

=cut
