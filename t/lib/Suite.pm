package Suite;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(assertion_files);

# Which files the suite's own guards read, decided once.
#
# Four guards hold this suite to standards it set itself: a denial must
# establish its subject, a refusal must say which refusal it got, every
# declared refusal must be exercised, and a board must be reached the way real
# usage reaches one. Each globbed t/*.t.
#
# Assertions also live in t/lib. A helper that calls Test::More::ok is making
# the claim on the test's behalf, and whoever reads the test sees it as the
# test's own - so it is the same claim, made where nothing was looking.
# t/lib/Shipped.pm asserts twice and t/lib/Run.pm once, and no guard had ever
# read either.
#
# Nothing was wrong in them, which is why nobody would have noticed: the fault
# is that nothing was looking. I introduced the first of those files while
# moving one decision out of nine tests into one helper - the right shape, and
# it quietly moved two assertions outside every check this suite makes of its
# own. TKT-259.
#
# Four copies of which files to read is the same drift shape one level up, so
# there is one list and the guards ask for it.
sub assertion_files {
    return ( sort glob 't/*.t' ), ( sort glob 't/lib/*.pm' );
}

1;

__END__

=head1 NAME

Suite - which files the suite's guards read

=head1 DESCRIPTION

The tests, and the helpers that assert on their behalf. An assertion moved into
a helper is the same assertion; it should not thereby leave the reach of every
guard this suite has.

=head1 FUNCTIONS

=head2 assertion_files

Every file that can carry an assertion, tests first and helpers after, each in
sorted order so a report reads the same way twice.

=cut
