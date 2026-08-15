#!/usr/bin/env perl
# A card that only moved column is not invisible.
#
# The column is not a field in the record - it is which directory the file sits
# in - so record_move renames the file, journals the move, and never rewrites
# the record. last_updated is untouched, and every since filter reads
# last_updated.
#
# So a card whose only change was moving column is hidden from
# record.list --since and dropped from an incremental export. Measured, both
# paths: a card created at 09:00 and moved to implement at 18:00 reports
# last_updated 09:00, and both filters asked for everything since 12:00 return
# nothing.
#
# The code says this must not happen. The comment above _changed_since reads:
# "since-filtering may skip quiet records but must never hide one." This hides
# one.
#
# The reference makes it a promise: "Export's envelope then carries now ... so a
# poller passes it back as its next --since and can never miss a change." A
# poller doing exactly that misses every column move, which on a board is the
# most visible change there is.
#
# Found while building board-still for TKT-177, which needed to know when a
# board last did anything. The obvious source was the newest last_updated, and a
# move did not appear in it - so that rule would have called a board busy with
# moves completely still.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-15T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Moved', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'MVS', epic_prefix => 'MVE', ticket_prefix => 'MVT',
);

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Its only change is where it sits' )->{ref};

my $before = $tira->record_show( project => $root, ref => $card )->{last_updated};
is( $before, '2026-08-15T09:00:00Z', 'a card is stamped when it is created' );

# --- moving it is changing it ----------------------------------------------------------

$now = '2026-08-15T18:00:00Z';
$tira->record_move( project => $root, ref => $card, column => 'implement' );

my $after = $tira->record_show( project => $root, ref => $card );
is( $after->{column}, 'implement', 'the card moved' );
is( $after->{last_updated}, '2026-08-15T18:00:00Z',
    'and the card says it changed when it moved' );

# --- so a since filter sees it ------------------------------------------------------------
#
# The comment above _changed_since is the standard this is held to: since
# filtering may skip quiet records but must never hide one.

{
    my $listed = $tira->record_list( project => $root,
        since => '2026-08-15T12:00:00Z', include_discard => 1 );
    is( scalar @{$listed}, 1,
        'a card whose only change was moving column is listed by a since filter covering the move' );
    is( $listed->[0]{ref}, $card, 'and it is the card that moved' );
}

# --- and so does an incremental export -----------------------------------------------------
#
# The promise in the reference: a poller passes the envelope's own clock back as
# its next --since and can never miss a change.

{
    my $exported = $tira->export_records( project => $root, since => '2026-08-15T12:00:00Z' );
    my $records = ref $exported eq 'HASH' ? ( $exported->{records} // [] ) : $exported;
    is( scalar @{$records}, 1,
        'and an incremental export carries it, which is what a poller depends on' );
}

# --- while a card that did not move is still skipped ------------------------------------------
#
# The filter must stay a filter. If everything were returned regardless this
# would pass while making the feature useless.

{
    $tira->create_record( project => $root, type => 'ticket',
        title => 'Raised long ago and left alone' );
    $now = '2026-08-16T09:00:00Z';

    my $listed = $tira->record_list( project => $root,
        since => '2026-08-16T08:00:00Z', include_discard => 1 );
    is( scalar @{$listed}, 0,
        'a card that has not changed since the threshold is still skipped' );
}

# --- and the content hash moves with it, as it always has ----------------------------------------
#
# CA05's own words: the hash covers every meaningful field including the
# computed column, so a no-op write keeps its hash while any real change,
# comment, attachment, or move alters it. Stamping the card must not disturb
# that contract in either direction.
#
# This block first asserted the opposite - that a move leaves the hash alone -
# and PASSED, because content_hash is only computed when a field selection asks
# for it and record_show without one returns undef. undef equalled undef and the
# assertion said nothing. Written an hour after TKT-196, which was about exactly
# that, and caught the same way: by mutating the thing it claimed to protect and
# watching nothing fail.

{
    my $settled = $tira->create_record( project => $root, type => 'ticket',
        title => 'Hash me' )->{ref};
    my $hash_before = $tira->record_show( project => $root, ref => $settled,
        fields => ['content_hash'] )->{content_hash};
    ok( defined $hash_before && length $hash_before,
        'a hash is only computed when it is asked for, so this asks' );

    $now = '2026-08-16T10:00:00Z';
    $tira->record_move( project => $root, ref => $settled, column => 'implement' );

    my $moved = $tira->record_show( project => $root, ref => $settled,
        fields => [ 'content_hash', 'last_updated' ] );
    isnt( $moved->{content_hash}, $hash_before,
        'a move alters the content hash, which is what CA05 promises of any real change' );
    is( $moved->{last_updated}, '2026-08-16T10:00:00Z',
        'and the card says when it changed' );
}

# --- a move that goes nowhere is not a change -----------------------------------------------------
#
# Moving a card to the column it is already in rewrites nothing and journals
# nothing, so it must not stamp the card either - otherwise a poller could be
# woken by a command that did nothing at all.

{
    my $still = $tira->create_record( project => $root, type => 'ticket',
        title => 'Going nowhere' )->{ref};
    my $stamp = $tira->record_show( project => $root, ref => $still )->{last_updated};

    $now = '2026-08-16T11:00:00Z';
    $tira->record_move( project => $root, ref => $still, column => 'backlog' );

    is( $tira->record_show( project => $root, ref => $still )->{last_updated}, $stamp,
        'moving a card to the column it is already in changes nothing, including the stamp' );
}

done_testing;

__END__

=head1 NAME

181-a-card-that-only-moved.t - a column change is a change

=head1 DESCRIPTION

The column is which directory a record's file sits in rather than a field
inside it, so C<record_move> renamed the file and never stamped the record.
Every C<--since> filter reads C<last_updated>, so a card whose only change was
moving column was hidden from C<record.list --since> and dropped from an
incremental export - against a comment saying since-filtering "must never hide
one" and a reference promising a poller "can never miss a change".

A move now stamps the card. The content hash is untouched, because the column
was never part of it, and a move to the column a card is already in still
changes nothing at all.

=cut
