package Suite;

use strict;
use warnings;

use File::Basename ();
use File::Find ();
use Test::More ();
use Exporter qw(import);
our @EXPORT_OK = qw(assertion_files engine_source cli_source view_source);

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

# The CLI layer, for guards that read what the command surface declares rather
# than what the engine does. The mirror image of engine_source: this one walks
# ONLY lib/Tira/CLI.pm and lib/Tira/CLI/, and the two together are lib/.
#
# It walks for the reason engine_source does. t/239 parsed %MISLEADING_OPTIONS
# and %OPTION_READ_BY out of lib/Tira/CLI.pm by name, and TKT-837 lifted both
# tables into lib/Tira/CLI/Options.pm to make room under t/430's cap - so the
# parse found nothing, the declared-refusal count fell to zero, and the test
# failed claiming a table was empty when it had merely moved. That is the same
# fault TKT-835 removed from seven engine tests: a test that opens a file by
# name is asserting where code lives while claiming to assert something else.
sub cli_source {
    my @modules;
    File::Find::find(
        { no_chdir => 1, wanted => sub {
              return if !/\.pm\z/;
              return if $File::Find::name !~ m{\blib/Tira/CLI(?:\.pm|/)};
              push @modules, $File::Find::name;
          } },
        'lib' );

    Test::More::cmp_ok( scalar @modules, '>=', 2,
        'lib/Tira/CLI was walked for command-surface source - ' . scalar(@modules) . ' modules' );

    my $source = '';
    for my $module ( sort @modules ) {
        open my $fh, '<:raw', $module or die "$module: $!";
        local $/;
        $source .= <$fh>;
    }
    return $source;
}

# A VIEW FILE, BY NAME RATHER THAN BY PATH. The third walker, and it does not
# concatenate the way the two above do - deliberately.
#
# engine_source() and cli_source() answer "does the engine say X anywhere",
# which is the right question for a layer. A test about jobs-editor.js is
# asking what THAT file does, and thirteen of them exist: hand them a
# concatenation of every view and an assertion starts matching another file's
# source and passing for the wrong reason. So this keeps each assertion
# pointed at one file while removing the thing that broke them - the path.
#
# lib/Tira/views/ is where they live today; the point is that no test needs to
# know that. TKT-921, and the same lesson as TKT-835: a test that opens a path
# is asserting where code lives while claiming to assert something else.
sub view_source {
    my ($name) = @_;

    my @found;
    File::Find::find(
        { no_chdir => 1, wanted => sub {
              push @found, $File::Find::name
                if ( File::Basename::basename($File::Find::name) eq ( $name // '' ) );
          } },
        'lib' );

    # DIES rather than returning empty. An empty string would be read by every
    # caller as "a file with none of what I asked for in it", which is the
    # absence-proven-by-a-broken-instrument fault the walkers above assert
    # their way out of - and a renamed view is exactly when this must shout.
    die "no view named '" . ( $name // '' ) . "' under lib/\n" if !@found;
    die "more than one file named '$name' under lib/: @found\n" if @found > 1;

    open my $fh, '<:encoding(UTF-8)', $found[0] or die "$found[0]: $!";
    local $/;
    return scalar <$fh>;
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

=head2 cli_source

The command surface - F<lib/Tira/CLI.pm> and everything under
F<lib/Tira/CLI/> - concatenated, for guards that read what the commands
declare rather than what the engine does. The mirror image of
C<engine_source>, and together the two are F<lib/>. TKT-837 lifted two option
tables out of F<lib/Tira/CLI.pm> and F<t/239>, which parsed them by filename,
reported a table as empty when it had merely moved.

=head2 view_source

One view file, found by B<basename> wherever it lives under F<lib/>. Dies if
the name matches nothing or more than one thing.

Not a concatenation, unlike the two above, and the difference is the point: a
test about F<jobs-editor.js> is asking what that file does, so handing it every
view would let an assertion match another file's source and pass for the wrong
reason. This removes the path without widening the subject. TKT-921.

=head2 assertion_files

Every file that can carry an assertion, tests first and helpers after, each in
sorted order so a report reads the same way twice.

=cut
