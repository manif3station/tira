#!/usr/bin/env perl
# A refusal test proves the refusal it was written for.
#
# Twenty-five tests capture a refusal as "my $refused = !eval { ... }". Fourteen
# of them asserted only that something died. Any death satisfied that: a renamed
# argument, a required field that moved, a typo in the rule name, an exception
# thrown three calls deeper. The refusal the test was written for could have
# stopped working and nothing would have said so.
#
# Proved rather than argued. In t/133 the call was pointed at a rule that does
# not exist, so the death came from "Unknown policy rule" and had nothing to do
# with the column being refused - and the test passed, reporting that a column
# on that rule is refused.
#
# It is the denial fault from TKT-141 in its other form. There the subject was
# never established, so emptiness passed; here the reason is never established,
# so any failure passes. Both report a promise kept about something that did not
# happen.
#
# A test that genuinely only cares that the call failed can say so, the same way
# a denial about something that ought to be empty says so.

use strict;
use warnings;

use Test::More;

use lib 't/lib';
use Suite qw(assertion_files);

my $DECLARED = qr/any failure is what this means/;

my ( $total, @silent ) = (0);
for my $file ( assertion_files() ) {
    open my $fh, '<:raw', $file or die "$file: $!";
    my @lines = <$fh>;
    close $fh;
    chomp @lines;

    for my $i ( 0 .. $#lines ) {
        # Prose that quotes the pattern is not a refusal. This file's own
        # opening paragraph names it, and a scan that read its own explanation
        # as code would be reporting itself.
        next if $lines[$i] =~ /\A\s*#/;

        next if $lines[$i] !~ /!\s*eval\s*\{/;
        my ($var) = $lines[$i] =~ /my\s+(\$\w+)\s*=\s*!\s*eval/ or next;
        $total++;

        my $declared = 0;
        for ( my $j = $i - 1; $j >= 0 && $lines[$j] =~ /\A\s*#/; $j-- ) {
            $declared = 1, last if $lines[$j] =~ $DECLARED;
        }
        next if $declared;

        # The message has to be asserted near the refusal it belongs to. A
        # window rather than the whole file, because two refusals in one test
        # would otherwise cover for each other - and covering for each other is
        # how this got here.
        my $said = 0;
        my $end = $i + 14 > $#lines ? $#lines : $i + 14;
        for my $j ( $i + 1 .. $end ) {
            $said = 1, last
              if $lines[$j] =~ /\$\@/ && $lines[$j] =~ /\b(?:like|is|isnt|ok|cmp_ok)\s*\(/;
        }
        push @silent, "$file:" . ( $i + 1 ) . " $var" if !$said;
    }
}

ok( $total, 'the suite captures refusals this way' );
is_deeply( \@silent, [],
    'and every one of them says which refusal it got, or declares that any failure is what it means' );

done_testing;

__END__

=head1 NAME

149-a-refusal-that-never-said-why.t - a refusal test proves the refusal it was written for

=head1 DESCRIPTION

Fourteen tests asserted that a call died without asserting why, so any death
satisfied them - a renamed argument, a moved requirement, a typo in a rule name.
Pointing one of them at a rule that does not exist made the death come from
somewhere else entirely and the test still passed.

Every captured refusal now asserts on the message, within sight of the refusal
it belongs to, or says in the comment above it that any failure is what it
means.

=cut
