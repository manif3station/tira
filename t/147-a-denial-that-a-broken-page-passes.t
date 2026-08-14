#!/usr/bin/env perl
# A denial means the thing was there and did not say it.
#
# unlike on an empty string passes. So a page that failed to render, a prompt
# that came back empty, or a command that printed nothing satisfies a denial and
# the test reports the promise kept.
#
# It happened here tonight. Under the autoflush change in TKT-132 the bridge
# went silent, and in t/102 the assertion 'narrowing just the same' passed on the
# empty output while its neighbours failed. That one assertion reported success
# about a bridge writing nothing at all.
#
# The worst instance was a privacy check: the login page test denied that the
# page names anybody, and would have said so about a page returning a five
# hundred. A security assertion satisfied by the thing being broken is worse
# than no assertion, because it is read as cover.
#
# Many denials are correct as they stand - a variable named for silence, an
# error stream that should be empty - and mechanically they look identical to
# the broken ones. So this is not a blanket rule. Where empty is the pass
# condition, the test says so in the comment above it, the way a card with no
# parent carries the standalone label: the difference is declared rather than
# assumed.

use strict;
use warnings;

use Test::More;

my $DECLARED = qr/empty is what passes/;

my @bare;
for my $file ( sort glob 't/*.t' ) {
    open my $fh, '<:raw', $file or die "$file: $!";
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    my $source = join "\n", @lines;

    for my $i ( 0 .. $#lines ) {
        my ($subject) = $lines[$i] =~ /\bunlike\(\s*([^,]+?)\s*,/ or next;
        next if $subject !~ /\A[\$\@]/;

        # Declared: this denial is about something that ought to be empty, and
        # emptiness passing is the answer rather than an accident. Read across
        # the whole comment block above it, because a declaration worth making
        # usually takes more than one line to explain, and a rule that only
        # looks at the line immediately above would push people into writing it
        # badly to satisfy the check.
        my $declared = 0;
        for ( my $j = $i - 1; $j >= 0 && $lines[$j] =~ /\A\s*#/; $j-- ) {
            $declared = 1, last if $lines[$j] =~ $DECLARED;
        }
        next if $declared;

        # Or established: something the denial is made of is asserted to be
        # what it should be, somewhere in the same file, so a denial about it
        # means what it says. Any variable in the expression will do - a denial
        # about "$out . $err" is about output that was established under its own
        # name a line earlier.
        my @named = ( $subject =~ /([\$\@]\w+|\$\@)/g );
        next if grep {
            my $base = quotemeta $_;

            # scalar @failures establishes $failures[0] just as surely as a
            # direct assertion would, and the error variable is established by
            # a like on the message it carries.
            $source =~ /(?:^|\s)(?:like|is|isnt|ok|cmp_ok|is_deeply)\(\s*(?:scalar\s+)?[\$\@]?$base(?!\w)/m
              || do { ( my $bare = $base ) =~ s/\A\\[\$\@]//;
                  $bare ne ''
                    && $source =~ /(?:^|\s)(?:like|is|isnt|ok|cmp_ok|is_deeply)\(\s*(?:scalar\s+)?[\$\@]$bare(?!\w)/m };
        } @named;

        push @bare, "$file:" . ( $i + 1 ) . " $subject";
    }
}

is_deeply( \@bare, [],
    'every denial either establishes its subject or declares that empty is what passes' );

# --- and the check itself is not vacuous ---------------------------------------
#
# A guard that finds nothing because its own pattern is wrong is the fault it
# exists to catch. It has to be shown finding something.

{
    # Assembled rather than written out, so this file carries no bare denial of
    # its own for the scan above to find. A demonstration that trips the check
    # it demonstrates would have to be excluded by name, and a check with an
    # exception in it is a check somebody will widen.
    my $sample = join "\n",
      'my $page = fetch();',
      'un' . q{like( $page, qr/secret/, 'says nothing secret' );};

    like( $sample, qr/\Qun\Elike\(/, 'the sample really contains a denial' );

    my @lines = split /\n/, $sample;
    my ($subject) = $lines[1] =~ /\bunlike\(\s*([^,]+?)\s*,/;
    is( $subject, '$page', 'the pattern picks the subject out of a denial' );

    my @named = ( $subject =~ /([\$\@]\w+|\$\@)/g );
    is_deeply( \@named, ['$page'], 'and the subject names one thing' );

    my $base = quotemeta $named[0];
    ok( $sample !~ /(?:^|\s)(?:like|is|isnt|ok|cmp_ok|is_deeply)\(\s*$base(?!\w)/m,
        'which nothing in the sample establishes, so the scan would call it bare' );
}

done_testing;

__END__

=head1 NAME

147-a-denial-that-a-broken-page-passes.t - a denial means the thing was there

=head1 DESCRIPTION

C<unlike> on an empty string passes, so a denial whose subject was never
established reports a promise kept when the subject failed to exist. The login
page privacy check was one: it would have reported that the page names nobody
about a page returning an error.

Every denial in the suite must either establish its subject somewhere in the
same file, or say in the comment above it that empty is what passes. Emptiness being
correct is common and legitimate; what this removes is the case where nobody
decided which of the two it was.

=cut
