#!/usr/bin/env perl
# A reader of the command reference is not missing a command.
#
# mt5-ai reported that tira.changes was documented in none of the three manuals.
# Two thirds of that was wrong and they withdrew it themselves - tira.skills
# names it four times - but the surviving third was real and is ours:
# docs/commands.md, the command reference, names none of it.
#
# Measuring it made it much larger than the report. The reference opens with
# "This is the reference: every command and argument, what it is for and when to
# use it", and tira.usage's own description repeats the promise. It named 84 of
# the 141 commands that ship. Fifty-seven were missing, including whole
# families: every attachment command, every checklist command, every column
# command, the collector commands, board.show, board.refs, assign.list.
#
# Not one of them was undocumented outright - all are in SKILLS.md - which is
# exactly why the existing check passed. docs-match-code concatenates the
# manual, the reference and the policies guide and asks whether a command
# appears anywhere in that pile. That is the right question for "is it
# documented at all" and the wrong one for "can a reader of the reference find
# it".
#
# Their pattern survived their own correction and is the reason this matters:
# three command families they could not find after capturing one document. A
# reference captured in part reads as complete.

use strict;
use warnings;

use File::Find;
use File::Spec;
use Test::More;

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

my @entrypoints;
find( sub { push @entrypoints, $File::Find::name if -f && ( $^O eq 'MSWin32' || -x _ ) },
    'cli', 'skills' );
@entrypoints = grep { m{(?:\A|/)cli/[^/]+\z} } @entrypoints;
ok( scalar @entrypoints, 'the release ships entrypoints to check' );

my $reference = slurp('docs/commands.md');

my @missing;
for my $path (@entrypoints) {
    my @parts = split m{/}, $path;
    my $action = pop @parts;
    pop @parts;
    shift @parts if $parts[0] eq 'cli';
    @parts = grep { $_ ne 'skills' } @parts;
    my $dotted = 'tira.' . join '.', @parts, $action;

    # The three boards share one set of verbs and are documented once as TYPE,
    # and the dashboard's three forms the same way. Requiring each spelling
    # would ask the document to repeat itself three times over.
    next if $dotted =~ /\Atira\.(?:sow|epic|ticket)\./;
    next if $dotted =~ /\Atira\.dashboard\./;

    push @missing, $dotted if index( $reference, $dotted ) < 0;
}

is_deeply( [ sort @missing ], [],
    'every command that ships is named in the command reference, which is what it says it is' );

# --- and the promise it makes about itself ------------------------------------------
#
# The document states its own contract in its first line, and tira.usage repeats
# it. A check that the commands are all there is worth little if the sentence
# claiming so has been quietly softened instead.

like( $reference, qr/every command and argument/,
    'the reference still claims to be every command and argument' );

# --- while the numbers in it are not left behind ---------------------------------------
#
# The same header said "Release 0.16" and "83 Developer Dashboard entrypoints"
# while the release was 1.69 and there were 141 - a count written in prose goes
# stale the moment anything is added, and nothing said so.

unlike( $reference, qr/Release 0\.16/,
    'and does not name a release from long before this one' );
unlike( $reference, qr/\b83 Developer/,
    'nor a count of entrypoints that stopped being true' );

done_testing;

__END__

=head1 NAME

162-the-reference-names-every-command.t - the reference names every command

=head1 DESCRIPTION

C<docs/commands.md> promises "every command and argument" and named 84 of the
141 that ship. The existing documentation check asks whether a command appears
in any of the three documents, which passes while a reader of the reference is
missing whole families - attachment, checklist, column, collector.

This asks the reference itself. It also holds the document to the promise in its
own first line, and to not carrying a release number and an entrypoint count
from long before the present one.

=cut
