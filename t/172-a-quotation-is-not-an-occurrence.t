#!/usr/bin/env perl
# A project can write about its own failures and still release.
#
# The documented-examples check scans a command's whole output for error text.
# tira.changes prints the changelog, and the 1.77 changelog describes a bug
# whose symptom was "Command project.show not found in skill tira" - so
# printing the changelog contained that sentence, and the push gate refused the
# release on the grounds that a shipped command does not exist.
#
# It is the third appearance of one shape. TKT-176 was a test that could fail
# by chance; TKT-184 is the gate judging uncommitted work; this is the gate
# reading a quotation as an occurrence. Each refuses a release for a reason
# that is not about the release, and a gate people retry past is not a gate.
#
# It would also have got worse on its own: every changelog entry about an error
# message adds another copy of that message to what tira.changes prints, so a
# project that writes carefully about its failures becomes progressively less
# able to ship.
#
# The scan is right for a command that answers and wrong for one that recites.
# For a reciter the exit status is the whole question - and that is stricter
# than the string scan, not looser, because a document that fails to print now
# fails rather than passing quietly.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Tira::CLI;

plan skip_all => 'python3 is not installed here' if !Tira::CLI::_program_exists('python3');

my $tool = 'tools/docs-examples-run';
ok( -x $tool, 'the documented-examples check ships and is runnable' );

open my $fh, '<', $tool or die "$tool: $!";
my $source = do { local $/; <$fh> };
close $fh;

# --- reciters are judged by whether they worked -------------------------------------

like( $source, qr/RECITERS/, 'the check knows which commands recite a document' );
like( $source, qr/RECITERS\s*=\s*\([^)]*tira\.changes/s,
    'and the changelog is one of them, which is the command that refused a release' );
like( $source, qr/returncode\s*!=\s*0/,
    'and asks whether they succeeded rather than what they said' );

# --- while everything else is still read for error text ---------------------------------
#
# A check that stopped scanning would be worse than the false alarm: the whole
# point is to catch documentation describing something Tira will not do.

like( $source, qr/for fatal in FATAL/,
    'a command that answers is still read for the failures that mean the documentation is wrong' );
like( $source, qr/not found in skill/,
    'and that list still contains the failure a vanished command produces' );

# --- the name that shadowed another --------------------------------------------------------
#
# The first version of this called the tuple DOCUMENTS, which already named the
# list of files to scan. The shadow made the check find zero examples, report
# them all understood, and exit 0 - a check that passes by having tried nothing,
# which is the exact fault this file exists to prevent one level down.

like( $source, qr/^DOCUMENTS\s*=\s*\([^)]*SKILLS\.md/m,
    'the list of documents to read still means the documents' );
unlike( $source, qr/^DOCUMENTS\s*=\s*\([^)]*tira\./m,
    'and is not shadowed by a list of command names' );

# --- proved by running it ------------------------------------------------------------------
#
# Reading the source shows the code says the right thing. This shows the thing
# it says is true: the real check, over the real documents, with a changelog
# that quotes an error message in it - which is what ships today.

{
    my $report = `python3 '$tool' 2>&1`;
    my $status = $? >> 8;
    is( $status, 0, 'the check passes against the documentation as it actually ships' )
      or diag($report);

    # And it did so having tried something. A count is asserted rather than an
    # exit status alone, because the shadow above passed by running nothing.
    my ($ran) = $report =~ /(\d+)\s+documented examples run/;
    ok( defined $ran && $ran > 100,
        "and having actually run them - $ran examples, not a silent zero" );
}

# --- while the changelog really does contain the sentence -----------------------------------
#
# If this stops being true the check above proves nothing, and it would stop
# being true quietly - somebody rewording a changelog entry would take the
# teeth out of this file without touching it.

{
    open my $log, '<:raw', 'Changes' or die "Changes: $!";
    my $changelog = do { local $/; <$log> };
    close $log;
    like( $changelog, qr/not found in skill/,
        'the changelog still quotes the error that caused this, so the check above is a real one' );
}

done_testing;

__END__

=head1 NAME

172-a-quotation-is-not-an-occurrence.t - writing about a failure does not become one

=head1 DESCRIPTION

C<tira.changes> prints the changelog, and the changelog describes a bug whose
symptom was C<Command project.show not found in skill tira>. The
documented-examples check scanned that output for error text and refused the
release, twice.

Commands that recite a document are now judged by their exit status, which is
stricter than the string scan: a document that fails to print fails the check
instead of passing quietly. Every other command is still read for the failures
that mean the documentation is describing something Tira will not do.

The first attempt named the new list C<DOCUMENTS>, shadowing the list of files
to scan, so the check found zero examples and reported success. That is why the
proof here asserts a count as well as an exit status.

=cut
