#!/usr/bin/env perl
# A string that looks like a number is still a string.
#
# TOON is the default output and the one every agent reads. Data::TOON tests a
# scalar against a number pattern before it tests whether it needs quoting, so
# a fix version of 2.20 was handed to the reader as 2.2 - a different release.
# 1.10 read as 1.1, 1.50 as 1.5, 1.90 as 1.9. Every release whose version ends
# in a zero has always come back as another one.
#
# Measured across this project's own board rather than argued: 20,732 string
# values, 22 of which did not survive a round trip through the default output,
# and 19 of those were a fix_version.
#
# Nothing in the suite would have caught it. No test named the encoder, and the
# JSON output the tests read is correct - the value on disk was right the whole
# time. It was found by accident, stamping a card with the release it went out
# in: I typed 2.20 and the board answered 2.2.
#
# The module has the right rule and cannot reach it. Its own _needs_quoting
# returns true for a numeric-looking string, and _encode_primitive returns the
# canonicalised number before ever asking. A check that exists and never fires.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Data::TOON;
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Released', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'RLS', epic_prefix => 'RLE', ticket_prefix => 'RLT',
);

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Went out in a release ending in a zero' );
$tira->record_update( author => 'claude', project => $root, ref => $card->{ref}, fix_version => '2.20' );

my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
is( $shown->{fix_version}, '2.20', 'the version on the card is the one it was given' );

# --- and the version the reader is handed ------------------------------------

my $toon = $tira->format_output( $shown, output => 'toon' );

# non-empty is the whole claim: a precondition for the assertions below, which
# would pass against an output that rendered nothing at all.
like( $toon, qr/\S/, 'the default output has something in it' );

like( $toon, qr/fix_version:\s*"2\.20"/,
    'and the version reads 2.20, as a string, because that is what it is' );

my $read_back = Data::TOON->decode($toon);
is( $read_back->{fix_version}, '2.20',
    'so somebody reading it gets the release that was set' );

# --- while a number is still a number ----------------------------------------
#
# The half that must not be lost: quoting everything would be as wrong in the
# other direction, and priority is a number on every card there is.

is( $read_back->{priority}, $shown->{priority},
    'a number is unchanged by this' );
unlike( $toon, qr/priority:\s*"/, 'and is not quoted' );
is_deeply( [ map { $read_back->{$_} } qw(ref title column) ],
    [ map { $shown->{$_} } qw(ref title column) ],
    'and the rest of the card reads back as itself' );

# --- proved by putting the fault back ----------------------------------------
#
# The module's own encoder, restored for the length of this block. It is kept
# for exactly this: a fix nobody can watch fail is a fix nobody can check.

{
    no warnings 'redefine';
    local *Data::TOON::Encoder::_encode_primitive = $Tira::TOON_PRIMITIVE_BEFORE;

    my $before = $tira->format_output( $shown, output => 'toon' );
    like( $before, qr/fix_version:\s*2\.2\b/,
        'without it the reader is handed 2.2, which is a different release' );
    isnt( Data::TOON->decode($before)->{fix_version}, '2.20',
        'and reading it back does not give the version that was set' );
}

# --- and back again -----------------------------------------------------------

like( $tira->format_output( $shown, output => 'toon' ), qr/fix_version:\s*"2\.20"/,
    'and the version reads as itself again' );

done_testing;

__END__

=head1 NAME

236-a-version-that-reads-back-as-itself.t - a string that looks like a number

=head1 DESCRIPTION

C<Data::TOON> canonicalises any scalar matching its number pattern, so a fix
version of C<2.20> was emitted as C<2.2> in the default output - the one every
agent reads. Nineteen cards on this project's board carried a version that read
back as a different release.

The module's own C<_needs_quoting> has the correct rule and is never reached
for these values. Tira restores the order for scalars Perl still knows are
strings, and only where leaving the value alone would change it.

=cut
