#!/usr/bin/env perl
# A card claimed fix_version 1.07 and Changes had no such release - a real
# gap left by a version bump whose entry never got written, found only by
# a reader cross-checking the two by hand, and it cost them an hour of
# archaeology. Two guards close it: fix_version refuses a value that is
# not a version at all (a word, rather than a released one), and
# changelog_check cross-references every card's claimed fix_version
# against a Changes file's own headings. TKT-347.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tira = Tira->new( clock => sub {'2026-08-23T09:00:00Z'} );
my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Versioned', dir => $root, members => ['claude'],
    sow_prefix => 'VRS', epic_prefix => 'VRE', ticket_prefix => 'VRT',
);

# --- fix_version refuses a value that is not a version -----------------------------

{
    eval { $tira->create_record( project => $root, type => 'ticket', title => 'x', fix_version => 'banana' ) };
    like( $@, qr/must be a released version/, 'creating with a word for fix_version is refused' );
}

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'x' );

{
    eval { $tira->record_update( project => $root, ref => $card->{ref}, fix_version => 'yes', author => 'claude' ) };
    like( $@, qr/must be a released version/, 'updating to a word for fix_version is refused too' );
}

# --- but the board's own established escape hatches still work --------------------

for my $value (qw(3.44 1.07 none)) {
    my $updated = $tira->record_update( project => $root, ref => $card->{ref}, fix_version => $value, author => 'claude' );
    is( $updated->{fix_version}, $value, "'$value' is accepted, unchanged" );
}
{
    my $updated = $tira->record_update( project => $root, ref => $card->{ref},
        fix_version => 'n/a - workspace tooling, no release', author => 'claude' );
    like( $updated->{fix_version}, qr/\An\/a\b/, "an 'n/a - ...' explanation is accepted too" );
}

# --- changelog_check finds a card claiming a version the changelog never released --

my $changes_file = File::Spec->catfile( $tmp, 'Changes' );
{
    open my $fh, '>', $changes_file or die $!;
    print {$fh} "Revision history\n\n3.44  2026-08-23\n    - something\n\n3.43  2026-08-23\n    - something else\n";
    close $fh;
}
$tira->record_update( project => $root, ref => $card->{ref}, fix_version => '1.07', author => 'claude' );

{
    my $result = $tira->changelog_check( project => $root, file => $changes_file );
    is( scalar @{ $result->{missing} }, 1, 'one card claims a version the changelog never released' );
    is( $result->{missing}[0]{ref}, $card->{ref}, 'naming the card' );
    is( $result->{missing}[0]{fix_version}, '1.07', 'and the version it claims' );
}

# --- writing the missing entry clears the finding -----------------------------------

{
    open my $fh, '>>', $changes_file or die $!;
    print {$fh} "\n1.07  2026-01-01\n    - the missing entry\n";
    close $fh;
}
{
    my $result = $tira->changelog_check( project => $root, file => $changes_file );
    is_deeply( $result->{missing}, [], 'once the changelog carries the entry, nothing is missing' );
}

# --- 'none' and 'n/a - ...' never count as a missing release ------------------------

$tira->record_update( project => $root, ref => $card->{ref}, fix_version => 'none', author => 'claude' );
{
    my $result = $tira->changelog_check( project => $root, file => $changes_file );
    is_deeply( $result->{missing}, [], "'none' is never reported as an unreleased version" );
}

done_testing;

__END__

=head1 NAME

339-a-version-nobody-released.t - fix_version validation and the board/changelog check

=head1 DESCRIPTION

A card claimed C<fix_version> 1.07 and C<Changes> had no such release - a
real gap left by a version bump whose entry never got written into the
changelog, found only by a reader cross-checking the two by hand.
C<fix_version> now refuses a value that plainly is not a version at all,
while still accepting the board's own established escape hatches (C<none>,
an C<n/a - ...> explanation). C<changelog_check> cross-references every
card's claimed C<fix_version> against a C<Changes> file's own version
headings, so the next hole is found by running the check rather than by a
probe. TKT-347.

=cut
