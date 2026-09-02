package Suite;

use strict;
use warnings;

use File::Find ();
use Test::More ();
use Exporter qw(import);
our @EXPORT_OK = qw(assertion_files engine_source);

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



# Every module under lib/, concatenated - the engine as one string, without
# any caller having to know which file a given sub sits in today.
#
# Nine tests used to open 'lib/Tira.pm' by name for this. That works only
# while the code they grep for happens to live there, and TKT-746 is
# deliberately moving it out one concern at a time: t/177 broke on TKT-834
# when %priority went to lib/Tira/Render.pm, and MISTAKE.md records four
# earlier instances from TKT-607's split, every one of which was the test
# being wrong rather than the change. Asking for "the engine" rather than
# for a filename is what makes those tests survive a lift that broke
# nothing. TKT-835.
#
# NOT for a test whose claim is ABOUT a particular module - t/430 reads
# lib/Tira/CLI.pm precisely to assert the index is smaller than the modules
# it indexes, and naming the file there is the whole point. This is for the
# other case, where the filename was only ever incidental.
sub engine_source {
    # THE ENGINE IS NOT EVERYTHING UNDER lib/. The CLI layer is excluded,
    # and the exclusion is load-bearing rather than tidy-minded: t/106
    # asserts the engine invokes no shell, which is the whole reason the
    # world is handed in to it - and lib/Tira/CLI/Serve.pm legitimately does
    # invoke one, because serving a board is exactly the job that needs it.
    # Sweeping the CLI in turned a true claim false. Measured rather than
    # assumed: Serve.pm is the only file under lib/ that matches t/106's
    # shell pattern at all.
    my @modules;
    File::Find::find(
        { no_chdir => 1, wanted => sub {
              return if !/\.pm\z/;
              return if $File::Find::name =~ m{\blib/Tira/CLI\b};
              push @modules, $File::Find::name;
          } },
        'lib' );

    # A read that found nothing returns the empty string, and every caller
    # then greps it and reports zero matches - the "absence proven by a
    # broken instrument" fault t/155 and t/176 both exist for. So the walk
    # asserts it found something before anything is read.
    Test::More::cmp_ok( scalar @modules, '>=', 4,
        'lib/ was walked for engine source - ' . scalar(@modules) . ' modules' );

    my $source = '';
    for my $module ( sort @modules ) {
        open my $fh, '<:raw', $module or die "$module: $!";
        local $/;
        $source .= <$fh>;
    }
    return $source;
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

=head2 engine_source

Every engine module under F<lib/> - that is, everything except the
C<Tira::CLI> layer - concatenated, so a test can ask for "the engine"
rather than for a filename. Nine tests used to open F<lib/Tira.pm> by name
for this, which works only while the code they grep for happens to live
there - and TKT-746 is deliberately moving it out one concern at a time.
Asserts that the walk found modules before reading any, so a broken read
cannot be mistaken for an absence. TKT-835.

Not for a test whose claim is about a particular module: F<t/430> reads
F<lib/Tira/CLI.pm> precisely to assert the index is smaller than the modules
it indexes, and naming the file there is the point.

=head2 assertion_files

Every file that can carry an assertion, tests first and helpers after, each in
sorted order so a report reads the same way twice.

=cut
