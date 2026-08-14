#!/usr/bin/env perl
# An assertion matches any non-empty text only where that is the whole claim.
#
# Found by the hourly hunt. Ten assertions across the suite matched with
# qr/\S/ - any non-empty text at all. Most were honest preconditions and said so
# in their own names: "the command answered at all, so the denial below is about
# an answer". At least one was not.
#
# t/95-windows-replace.t asserted like($@, qr/\S/, 'and says why'), and the
# proof is a mutation rather than an argument: stripping the reason from the
# message - die "Cannot replace $path" instead of "Cannot replace $path:
# $error" - left "ok 10 - and says why" passing and the whole file green. An
# assertion promising that an error explains itself, unable to tell whether it
# did.
#
# The code was right. The message really does read "Cannot replace ...:
# Permission denied". What was wrong was a guard that would not have noticed if
# it stopped.
#
# One of the ten was written an hour before this file, widening an assertion
# after the failure it described changed shape. That is how they get in: a
# specific pattern stops matching, and the quickest repair is to stop matching
# anything.
#
# So the difference is written down rather than judged case by case. Where
# non-empty IS the claim - a prompt exists, a command answered, a log was
# written - the line says so with a named marker, the way t/147 and t/149
# already mark their allowed exceptions. Everywhere else, an assertion pins what
# its name promises.

use strict;
use warnings;

use File::Spec;
use Test::More;

my $MARKER = 'non-empty is the whole claim';

opendir my $dh, 't' or die "t: $!";
my @files = sort grep { /\.t\z/ } readdir $dh;
closedir $dh;
ok( scalar @files > 100, 'there is a suite to check' );

my @unmarked;
my $marked = 0;

for my $name (@files) {
    my $path = File::Spec->catfile( 't', $name );
    open my $fh, '<', $path or die "$path: $!";
    my @lines = <$fh>;
    close $fh;

    for my $i ( 0 .. $#lines ) {
        my $line = $lines[$i];

        # Prose about an assertion is not an assertion. This file quotes the
        # very line that prompted it, and the first run reported its own header
        # as a defect - the same trap t/149 fell into and marks against.
        next if $line =~ /\A\s*#/;

        # And a quoted example of an assertion is not one either. The block
        # below carries two on purpose, to show this check can tell a marked
        # line from an unmarked one, and the second run reported them as
        # findings.
        next if $line =~ /\A\s*q\{/;
        next if $line !~ /\b(?:un)?like\s*\(/;
        next if $line !~ /qr\/\\S\//;

        # The marker may sit on the line itself or in the comment block
        # immediately above it, because an explanation worth writing rarely
        # fits on the end of an assertion.
        my $context = join '', @lines[ ( $i >= 4 ? $i - 4 : 0 ) .. $i ];
        if ( index( $context, $MARKER ) >= 0 ) {
            $marked++;
            next;
        }
        push @unmarked, "$name:" . ( $i + 1 ) . ' ' . ( $line =~ s/\A\s+|\s+\z//gr );
    }
}

is_deeply( \@unmarked, [],
    'every assertion that matches any non-empty text says that is the whole claim' );

ok( $marked > 0,
    "and the ones that legitimately do are marked - $marked of them" );

# --- the marker is not a way of turning the check off -----------------------------------
#
# It has to be written on the line, by somebody who has thought about it. A
# check whose exception is a file of names is one that gets widened; a check
# whose exception is a sentence beside the assertion is one anybody reading the
# test can weigh.

{
    my @sample = (
        q{like( $out, qr/\S/, 'it answered at all' );},
        q{like( $@, qr/\S/, 'and says why' );},
    );
    my @caught = grep { !/\Q$MARKER\E/ } @sample;
    is( scalar @caught, 2, 'the pattern finds an unmarked assertion' );

    my @allowed = grep { !/\Q$MARKER\E/ }
      ( "# $MARKER\n" . $sample[0] );
    is( scalar @allowed, 0, 'and a marked one is allowed through' );
}

# --- and the one that started this stays pinned -------------------------------------------
#
# Named, because a guard that is green everywhere says nothing about whether it
# would have caught the case it was written for.

{
    open my $fh, '<', 't/95-windows-replace.t' or die $!;
    my $source = do { local $/; <$fh> };
    close $fh;
    like( $source, qr/Permission denied/,
        'the replace failure asserts the reason the system gave, not merely that there was text' );
    unlike( $source, qr/qr\/\\S\/, 'and says why'/,
        'and no longer claims to check an explanation it never read' );
}

done_testing;

__END__

=head1 NAME

176-an-assertion-that-cannot-fail.t - non-empty is asserted only where it is the claim

=head1 DESCRIPTION

Ten assertions in the suite matched C<qr/\S/> - any non-empty text. Most were
honest preconditions. One, C<t/95-windows-replace.t>'s C<'and says why'>, was
not: stripping the reason out of the error message left it passing.

Assertions that match any non-empty text now have to say that non-empty is the
whole claim, in a marker beside them. Everywhere else an assertion pins what its
name promises, so a message that stops explaining itself fails the test that
says it explains itself.

=cut
