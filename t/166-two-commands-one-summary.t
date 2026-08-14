#!/usr/bin/env perl
# Two commands do not claim to do the same specific thing.
#
# tira.backup.export and tira.backup.import both described themselves as "Put
# the board back to its last backup". That is what tira.backup.restore does and
# what neither of them does: export writes a bundle out, import reads one into a
# board that has none. Both also carried the same half-finished sentence -
# "delegates to Tira::CLI, which resets the a git bundle holding the board's
# whole history".
#
# It is a wrong-action risk rather than an untidy comment. Somebody reading "Put
# the board back to its last backup" on the export entrypoint could run export
# believing it restores, and export is the one that writes a file - so the
# mistake stays quiet until the day they need the restore they thought they had.
#
# Found by the hourly hunt, and the first probe of that hunt passed both files.
# It asserted that a NAME line contains the command it resolves to, and both do.
# The second probe - summaries used by more than one entrypoint - is what found
# it, so that is the shape kept here.
#
# 110 of the 130 entrypoints share one summary, the shared dispatcher's, because
# those files really are copies of it. That is allowed by name: an exception
# written as a list of files is one somebody widens, and an exception written as
# a single known string is one anybody can check.

use strict;
use warnings;

use File::Find;
use File::Spec;
use Test::More;

# The one summary that is legitimately shared: these files are the dispatcher,
# copied, and their documentation describes the dispatcher accurately. What they
# do not say is what each command does - the command reference names all of them
# with their synopses, which is where a reader is sent.
my $DISPATCHER = 'Resolve a dotted Developer Dashboard command';

my @entrypoints;
find( sub { push @entrypoints, $File::Find::name if -f && ( $^O eq 'MSWin32' || -x _ ) },
    'cli', 'skills' );
@entrypoints = grep { m{(?:\A|/)cli/[^/]+\z} } @entrypoints;
ok( scalar @entrypoints, 'the release ships entrypoints to check' );

my %by_summary;
my $described = 0;
for my $path (@entrypoints) {
    open my $fh, '<', $path or die "$path: $!";
    my $source = do { local $/; <$fh> };
    close $fh;
    my ($name) = $source =~ /=head1 NAME\s*\n\s*\n([^\n]+)/ or next;
    my ($summary) = $name =~ /\s+-\s+(.+?)\s*\z/ or next;
    $described++;
    next if $summary eq $DISPATCHER;
    push @{ $by_summary{ lc $summary } }, $path;
}
ok( $described, 'and they describe themselves' );

my @shared = map { "$_: " . join ', ', @{ $by_summary{$_} } }
  sort grep { @{ $by_summary{$_} } > 1 } keys %by_summary;
is_deeply( \@shared, [],
    'no two commands claim to do the same specific thing' );

# --- the two that did ------------------------------------------------------------------
#
# Named, because a check that is green everywhere says nothing about whether it
# would have caught this one.

for my $case (
    [ 'skills/backup/cli/export', qr/bundle/i,  qr/back to its last backup/ ],
    [ 'skills/backup/cli/import', qr/bundle/i,  qr/back to its last backup/ ],
) {
    my ( $path, $wanted, $unwanted ) = @{$case};
    open my $fh, '<', $path or die "$path: $!";
    my $source = do { local $/; <$fh> };
    close $fh;
    my ($name) = $source =~ /=head1 NAME\s*\n\s*\n([^\n]+)/;
    like( $name, $wanted, "$path says it is about a bundle" );
    unlike( $name, $unwanted, "and $path no longer describes what restore does" );
}

# --- and restore keeps the sentence that was its own --------------------------------------

{
    open my $fh, '<', 'skills/backup/cli/restore' or die $!;
    my $source = do { local $/; <$fh> };
    close $fh;
    like( $source, qr/back to its last backup/,
        'restore still says it puts the board back, which was always true of it' );
}

# --- the check can find something ----------------------------------------------------------
#
# A guard that is green because its pattern is wrong is the fault it exists to
# catch, so it is shown picking a summary out of a NAME line and matching two.

{
    my @sample = (
        'tira.one - Put the board back to its last backup',
        'tira.two - Put the board back to its last backup',
        "tira.three - $DISPATCHER",
    );
    my %seen;
    for my $line (@sample) {
        my ($summary) = $line =~ /\s+-\s+(.+?)\s*\z/;
        next if $summary eq $DISPATCHER;
        push @{ $seen{ lc $summary } }, $line;
    }
    is( scalar( keys %seen ), 1, 'the pattern pulls one specific summary out of three lines' );
    is( scalar( @{ ( values %seen )[0] } ), 2, 'and sees that two of them share it' );
}

done_testing;

__END__

=head1 NAME

166-two-commands-one-summary.t - two commands do not claim the same specific thing

=head1 DESCRIPTION

C<tira.backup.export> and C<tira.backup.import> both described themselves as
putting the board back to its last backup, which is C<restore>'s job and neither
of theirs - a wrong-action risk, because export writes a file and the mistake
stays quiet until somebody needs the restore they thought they had.

Every summary must now be unique, except the shared dispatcher's, which 110
entrypoints carry because those files really are copies of it. The exception is
a single known string rather than a list of files, so anybody can check it.

=cut
