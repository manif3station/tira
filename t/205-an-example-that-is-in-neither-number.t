#!/usr/bin/env perl
# Every documented example is either run or set aside, and none is invisible.
#
# t/155 made the check say how many it ran and how many it set aside, so that
# "130 examples run" could not be read as all of them. That covered the examples
# the collector had found. It said nothing about the ones it never found at all,
# which are in neither number and so cannot be noticed from the summary.
#
# The collector allowed at most two leading spaces. Both documents indent their
# worked examples by four, so nineteen distinct examples were collected by
# nothing: not run, not set aside, not counted, not named. The newest passages
# are the ones written in the four-space style, which means the commands added
# most recently were the least likely to be tried - tira.doctor and
# tira.doctor --repair among them.
#
# The same silence was found here once before, for a different reason: the d2
# form was missing and all 132 of the policies guide's examples matched neither
# pattern. That was fixed by widening the pattern, which left the next variation
# to be discovered the same way. So this asserts the accounting rather than the
# pattern: whatever the collector matches, every example line in the documents
# must appear in one of the two numbers.

use strict;
use warnings;

use File::Spec;
use Test::More;

use lib 'lib';
use Tira::CLI;

plan skip_all => 'python3 is not installed here'
  if !Tira::CLI::_program_exists('python3');

my $tool = File::Spec->catfile(qw(tools docs-examples-run));
ok( -x $tool, 'the documentation check ships and is runnable' );

open my $fh, '<', $tool or die "Cannot read $tool: $!";
my $source = do { local $/; <$fh> };
close $fh;

# The collector's own pattern, read out of the tool rather than repeated here -
# a copy would drift from it and then assert nothing about what ships.
my ($pattern) = $source =~ /^FENCED\s*=\s*re\.compile\(r'(.*?)'\s*,\s*re\.M\)/m;
ok( $pattern, 'the collector names the shape of an example in one place' );

like(
    $source,
    qr/unaccounted|accounted/,
    'the check accounts for every example line, so one can not be missed by being matched by nothing'
);

# What the pattern DOES, not what it is spelled like.
#
# Asserting on the text of a pattern is wrong in both directions: a correct
# rewrite with different spelling fails, and a broken pattern that happens to
# contain the right characters passes. This ran the first version of that
# mistake - it checked the pattern did not contain \s{0,N} and did contain a
# hash - which says nothing about whether a four-space example is collected.
#
# So the pattern is taken out of the tool and applied to lines, through the same
# engine that uses it. Perl and Python agree on this much regular expression.
my %behaviour = (
    '    d2 tira.doctor'                        => 1,
    'd2 tira.doctor              # what broke'  => 1,
    'd2 tira.export --count'                    => 1,
    'tira.stale [--type TYPE] [-o FORMAT]'      => 0,
    'tira.doctor repairs damage in place.'      => 0,
);

# Python's \s and Perl's agree; the pattern uses nothing else that differs.
my $perl = $pattern;
$perl =~ s/\(\?:/(?:/g;

for my $line ( sort keys %behaviour ) {
    my $wanted = $behaviour{$line};
    my $got = ( $line =~ /$perl/ ) ? 1 : 0;
    is( $got, $wanted,
        $wanted
        ? "an example like '$line' is collected"
        : "but '$line' is not an example and is left alone" );
}

done_testing;

__END__

=head1 NAME

205-an-example-that-is-in-neither-number.t - found, or visibly not

=head1 DESCRIPTION

C<t/155> made the documentation check report what it ran and what it set aside,
so the first number could not be read as all of them. That covers examples the
collector found. An example the collector never matches is in neither number,
and nothing in the summary can reveal it.

Nineteen were in that state: the pattern allowed at most two leading spaces
while both documents indent worked examples by four.

This asserts the accounting rather than the pattern, because widening a pattern
fixes one variation and leaves the next to be found the same way.

=cut
