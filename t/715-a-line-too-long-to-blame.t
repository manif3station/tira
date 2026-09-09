#!/usr/bin/env perl
# The view assets kept their minified single lines, so a dashboard change
# still cannot be reviewed as a diff.
#
# TKT-703 moved the dashboard's front-end out of lib/Tira.pm and into
# lib/Tira/views, extracting every asset VERBATIM to prove the page came out
# byte-identical. That was the right proof for that card and the wrong shape
# to leave behind: several assets kept the single enormous line they had as
# Perl strings, so an edit to any one of them is still a scripted replace
# against an exact substring rather than something git can render as a diff.
#
# t/426 asserts this same threshold - no line over 2,000 characters - against
# lib/Tira.pm, and says nothing about the assets, correctly for that card.
# This file is the same assertion extended over lib/Tira/views, which is why
# it is red now: a formatter has not touched these files yet.
#
# Deliberately not committed as part of TKT-703 or any other in-flight card -
# a failing file in t/ turns every other card's verify run red, so this one is
# only added once the ticket that owns making it green (TKT-715) is actually
# in tests-red.

use strict;
use warnings;

use Test::More;

my @files = grep { -f } glob('lib/Tira/views/*');
ok( scalar @files, 'lib/Tira/views ships at least one asset - found '
      . scalar(@files) );

my %offenders;
for my $file (@files) {
    open my $fh, '<', $file or die "cannot read $file: $!";
    local $/;
    my $source = <$fh>;
    close $fh;

    my @lines = split /\n/, $source;
    my @long  = grep { length( $lines[$_] ) > 2_000 } 0 .. $#lines;
    next if !@long;

    my $held = 0;
    $held += length( $lines[$_] ) for @long;
    my ($longest) =
      sort { length( $lines[$b] ) <=> length( $lines[$a] ) } @long;

    $offenders{$file} = {
        count   => scalar(@long),
        held    => $held,
        longest => length( $lines[$longest] ),
    };
}

is_deeply( \%offenders, {},
    'no asset under lib/Tira/views carries a line longer than 2,000 '
      . 'characters - '
      . join( '; ',
        map { "$_: $offenders{$_}{count} line(s), longest $offenders{$_}{longest} bytes" }
          sort keys %offenders ) );

done_testing();

__END__

=head1 NAME

t/715-a-line-too-long-to-blame.t - a dashboard asset must be reviewable as a
diff, not just parseable as a file

=head1 DESCRIPTION

TKT-703 extracted the dashboard's front-end out of lib/Tira.pm verbatim, which
proved the move changed nothing and left several assets exactly as long a
single line as they were as Perl strings. Byte-equality of the source was the
right proof for that card; it is not the reason the move was asked for, which
was TKT-645's discovery that a 53KB line cannot be edited except by a scripted
replace against an exact substring.

This file extends t/426's own threshold - no line over 2,000 characters - from
lib/Tira.pm to the directory that inherited its content. It is deliberately
red until TKT-715 reformats the offending assets with a real formatter.

=cut
