#!/usr/bin/env perl
# A number in a gate is a claim the gate actually made.
#
# tools/docs-examples-run finds one hundred and ninety example lines in the
# documents, runs one hundred and thirty, and drops sixty without a word. Its
# last line - "130 documented examples run, and every one was understood" - is
# read in the push gate as the documentation having been checked. Nearly a third
# of it was never tried.
#
# Skipping is not the fault. Most of the sixty carry a shape a reader is meant
# to replace - a sha placeholder, TYPE, an optional format flag - and running
# those would prove nothing. Reporting them as though they had been checked is
# the fault.
#
# The tool has already been bitten by exactly this. Its own header records that
# treating a quoted project name as a shape "skipped the example silently, which
# is how a deliberately broken example passed this check". The quoting was fixed
# and the silence was left.
#
# And some of the sixty are real. "tira.board.refs --type ticket --prefix DEV
# --digits 5" is dropped because DEV is capitals, and DEV is a value somebody
# types. Once the skips are visible, that can be looked at instead of never
# noticed.

use strict;
use warnings;

use File::Spec;
use Test::More;

use lib 'lib', 't/lib';
use Shipped qw(runnable_ok);
use Tira::CLI;
# Tira::CLI::Serve holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Serve;

plan skip_all => 'python3 is not installed here' if !Tira::CLI::Serve::_program_exists('python3');

my $tool = File::Spec->catfile(qw(tools docs-examples-run));
runnable_ok( $tool, 'the documentation check ships and is runnable' );

open my $fh, '<', $tool or die $!;
my $source = do { local $/; <$fh> };
close $fh;

# --- nothing leaves without being counted -----------------------------------------
#
# The check reads its own source rather than running it, because running it
# takes a scratch board and a few hundred commands and belongs to the push gate.
# What is asserted is the shape that made the number a claim it had not earned:
# an example that matches a placeholder was dropped by a bare next, and the
# report only ever knew about the ones that ran.

# In the code rather than in the prose. This assertion first passed on the word
# appearing in the header comment that describes the very fault being fixed,
# which is the shape it exists to remove.
like( $source, qr/set_aside\.append\(/,
    'the check keeps what it set aside, in code rather than in a comment about it' );

# The whole statement, because the summary is an f-string spread over several
# lines and reading only its first fragment is how a check ends up asserting
# half of what it meant to.
#
# The summary is picked out by what it says, not by being the first statement
# with that prefix. It was written the other way and passed for as long as the
# tool printed exactly one such line; 1.98 added a second - the report of
# examples collected by nothing - which comes first because it returns early,
# and these three assertions silently moved onto it. Selecting by position works
# until something is added above, and then it does not announce that it moved.
my ($report) = $source =~ /(print\(f'docs-examples-run: \{ran\}.*?\)\n)/s;
ok( $report, 'it prints a summary line at the end' );
like( $report, qr/\{ran\}/, 'saying how many it ran' );
like( $report, qr/\{len\(skipped\)\}/,
    'and how many it did not, so the first number is not read as all of them' );

# --- and the skipped ones can be looked at -------------------------------------------
#
# A count alone would say a third went untried without saying which third, and
# the case worth finding - a real value mistaken for a shape - is only visible
# by name.

like( $source, qr/TIRA_EXAMPLES_SHOW_SKIPPED|--show-skipped|for .*skipped/,
    'and the ones it set aside can be named rather than only counted' );

# --- and the form the guide is actually written in ----------------------------------
#
# The bigger half, found by breaking a documented example and watching the check
# report everything understood. Examples were collected as backticked
# "dashboard tira...." or a bare "tira...." at the start of a line; the policies
# guide writes all of its examples as "d2 tira....", so the document with by far
# the most worked examples in it was listed for checking and contributed none.

like( $source, qr/d2\\s\+\|dashboard\\s\+/,
    'the dispatcher is collected however the document writes it' );
like( $source, qr/CONTINUED/,
    'and half a command, ending in a backslash, is set aside rather than run as if whole' );
like( $source, qr/comments=True/,
    'while a trailing note to the reader is a comment, not an argument' );

# --- while it still fails on an example the command will not accept --------------------
#
# The reason the check exists. Making the report honest must not soften what it
# refuses: a documented example naming an option that does not exist is the
# documentation describing something Tira will not do.

like( $source, qr/'Unknown option'/, 'an option that does not exist is still fatal' );
like( $source, qr/'Unsupported Tira command'/, 'and so is a command that does not exist' );
like( $source, qr/return 1/, 'and it still exits non-zero when it finds one' );

done_testing;

__END__

=head1 NAME

155-a-check-that-counts-only-what-it-tried.t - a number in a gate is a claim it made

=head1 DESCRIPTION

C<tools/docs-examples-run> ran 130 of the 190 example lines it found and dropped
60 silently, then reported the 130 as though the documentation had been checked.
The tool's own header records that silent skipping is how a deliberately broken
example once passed it.

The report now separates what ran from what was set aside, and the skipped ones
can be named - which is the only way to see the cases where a real value was
mistaken for a placeholder. What it refuses is unchanged.

=cut
