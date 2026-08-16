#!/usr/bin/env perl
# An assertion in a helper is held to the same standard as one in a test.
#
# Four guards hold this suite to standards it set itself, and each globbed
# t/*.t. Assertions also live in t/lib, where a helper makes a claim on a
# test's behalf - t/lib/Shipped.pm asserts twice, t/lib/Run.pm once - and no
# guard had ever read either file.
#
# Nothing was wrong in them, which is exactly why nobody would have noticed:
# the fault is that nothing was looking. I introduced the first of those files
# while moving one decision out of nine tests into one helper, which is the
# right shape, and it quietly moved two assertions outside every check this
# suite makes of its own assertions.
#
# Proved by running rather than by reading. A guard is copied into a directory
# of its own with a helper that carries the fault it exists to catch, and has
# to report it; then the list is narrowed back to the tests alone and the same
# guard has to fall silent, because that is what it did for the life of the
# suite until now.

use strict;
use warnings;

use Cwd qw(getcwd);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Run qw(run_capturing);
use Suite qw(assertion_files);

# --- the one list ------------------------------------------------------------

my @files = assertion_files();

cmp_ok( scalar @files, '>', 100, 'there is a suite to read' );

my @helpers = grep { m{\At/lib/} } @files;
cmp_ok( scalar @helpers, '>=', 3,
    'and the helpers that assert on a test\'s behalf are in it' );

my @tests = grep { m{\At/[^/]+\.t\z} } @files;
is( scalar @tests, scalar( () = glob 't/*.t' ),
    'along with every test file, so nothing was traded for the helpers' );

# --- and each guard asks for it ----------------------------------------------
#
# Read rather than run, because what is asserted here is that no guard keeps a
# list of its own - four copies of which files to read being the same drift
# shape one level up. That they work is the business of the block below.

for my $guard (
    't/147-a-denial-that-a-broken-page-passes.t',
    't/149-a-refusal-that-never-said-why.t',
    't/213-how-the-suite-reaches-a-board.t',
    't/79-policy.t',
  )
{
    open my $fh, '<', $guard or die "$guard: $!";
    my $text = do { local $/; <$fh> };
    close $fh;

    like( $text, qr/assertion_files\(\)/, "$guard asks which files to read" );
    unlike( $text, qr/glob\s+'t\/\*\.t'/, "$guard keeps no list of its own" );
}

# --- a helper carrying the fault a guard exists to catch ---------------------

my $tmp = tempdir( CLEANUP => 1 );
make_path( File::Spec->catdir( $tmp, 't', 'lib' ) );

# The guard under test, and the list it asks. Copied rather than pointed at, so
# the fixture directory is all it can see.
for my $file ( 't/147-a-denial-that-a-broken-page-passes.t', 't/lib/Suite.pm' ) {
    open my $in, '<', $file or die "$file: $!";
    my $text = do { local $/; <$in> };
    close $in;
    open my $out, '>', File::Spec->catfile( $tmp, $file ) or die $!;
    print {$out} $text;
    close $out;
}

# A helper that denies something about a value it never established, which is
# the one thing t/147 exists to find. Assembled rather than written out, so
# this file carries no bare denial of its own.
my $poisoned = File::Spec->catfile( $tmp, 't', 'lib', 'Poisoned.pm' );
{
    open my $fh, '>', $poisoned or die $!;
    print {$fh} join "\n",
      'package Poisoned;',
      'sub check {',
      '    my $page = fetch();',
      '    Test::More::un' . q{like( $page, qr/secret/, 'says nothing secret' );},
      '}',
      '1;',
      '';
    close $fh;
}

sub guard_says {
    my $here = getcwd();
    chdir $tmp or die "chdir: $!";
    my ( $status, $said ) =
      run_capturing( $^X, '-I', File::Spec->catdir( $tmp, 't', 'lib' ),
        't/147-a-denial-that-a-broken-page-passes.t' );
    chdir $here or die "chdir back: $!";
    return ( $status, $said );
}

{
    my ( $status, $said ) = guard_says();
    isnt( $status, 0, 'a bare denial in a helper is reported' );
    like( $said, qr/Poisoned\.pm/, 'naming the helper it is in' );
}

# --- and with the list narrowed back to the tests alone ----------------------
#
# What the guard did for the life of this suite: the same helper, the same
# fault, and nothing said.

{
    my $narrowed = File::Spec->catfile( $tmp, 't', 'lib', 'Suite.pm' );
    open my $fh, '<', $narrowed or die $!;
    my $text = do { local $/; <$fh> };
    close $fh;
    $text =~ s/\Qreturn ( sort glob 't\/*.t' ), ( sort glob 't\/lib\/*.pm' );\E/return sort glob 't\/*.t';/
      or die 'the list did not narrow - this proof would have proved nothing';
    open my $out, '>', $narrowed or die $!;
    print {$out} $text;
    close $out;

    my ( $status, $said ) = guard_says();
    is( $status, 0, 'with only the tests read, the same fault passes' );

    # non-empty is the whole claim here: the guard still ran and still had
    # something to say, so its silence about the helper is a choice of what to
    # read rather than a file that failed to run at all.
    like( $said, qr/\S/, 'while the guard itself still runs' );
}

done_testing;

__END__

=head1 NAME

243-what-the-guards-read.t - the tests, and the helpers that assert for them

=head1 DESCRIPTION

Four guards each globbed C<t/*.t>, so an assertion moved into C<t/lib> left the
reach of every check this suite makes of its own assertions. They now ask one
place which files to read, and that place includes the helpers.

Proved by running: a helper carrying the fault C<t/147> exists to catch is
reported, and with the list narrowed back to the tests alone the same fault
passes - which is what happened for the life of the suite.

=cut
