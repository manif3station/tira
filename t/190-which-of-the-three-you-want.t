#!/usr/bin/env perl
# Three commands that sound alike, and which one a backup means.
#
# Another project read tira.backup.export as the way to back a board up. That is
# the one reading that loses work: an export is a file somebody has to remember
# to make, and a board with exports and no backups has nothing to restore from
# when the thing it protects against happens.
#
# His words for what each is: export is used when you move a Tira project to
# another machine, import when the other machine receives it, and day-to-day
# operation uses neither.
#
# A documentation card gets a test for the same reason any other does. The three
# passages agree with each other today; nothing has been stopping them drifting
# apart, and the reading that caused this was somebody doing their best with
# what was written.

use strict;
use warnings;

use Test::More;

sub document {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

my %doc = map { $_ => document($_) } ( 'SKILLS.md', 'docs/commands.md' );

for my $path ( sort keys %doc ) {
    my $text = $doc{$path};

    # The sentence that answers the question somebody actually has.
    like( $text, qr/tira\.backup\b[^\n]{0,200}\bis the backup\b|\bis the backup\b[^\n]{0,200}tira\.backup/,
        "$path says which of the three is the backup" );

    # And what the other two are for, in the words he used.
    like( $text, qr/another machine/i,
        "$path says export and import are about moving a board between machines" );
    like( $text, qr/day-to-day|day to day/i,
        "$path says day-to-day work uses neither" );
}

done_testing;

__END__

=head1 NAME

190-which-of-the-three-you-want.t - backup, export and import are not the same thing

=head1 DESCRIPTION

A project read C<tira.backup.export> as the way to back a board up, which is the
reading that loses work. Both documents now say which of the three is the
backup, that export and import move a board between machines, and that
day-to-day operation uses neither.

=cut
