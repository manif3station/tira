#!/usr/bin/env perl
# column_apply replaced a board's whole layout as several separate
# transactions, so a failure partway through left neither the old layout
# nor the new one.
#
# TKT-767. Read at lib/Tira.pm: validation ran first and correctly refused
# before anything was written, but the writes themselves were not one
# operation - each removal took its own project lock (column_remove is not
# reentrant), and the rest of the layout (labels, order, notify_after,
# watched, new columns) was a separate, later transaction. A removal that
# died partway - a second column already gone from under it, a permission
# error - left some columns removed (their cards already discarded) and the
# rest of the intended layout never attempted: no way back to the old
# layout, no way forward to the new one.
#
# This project already found and fixed exactly this shape once, in a
# different command (TKT-569, release.record's batch mode) - not a
# precedent to generalize blindly, since that is a genuinely batch-shaped
# operation, but the same principle applies here: one lock, all-or-nothing.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite;
use Tira;

sub names {
    my ( $tira, $root ) = @_;
    return [ map { $_->{name} } @{ $tira->column_list( project => $root, type => 'ticket' ) } ];
}

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new( clock => sub { '2026-09-05T03:40:00Z' } );
$tira->project_new(
    project => $root, name => 'Layout', dir => $root, members => ['claude'],
    columns => ['backlog, mid1, mid2, done'],
    sow_prefix => 'LYS', epic_prefix => 'LYE', ticket_prefix => 'LYT',
);

my $one = $tira->create_record( project => $root, type => 'ticket', title => 'Card in mid1' );
$tira->record_move( author => 'claude', project => $root, ref => $one->{ref}, column => 'mid1' );

my $before = names( $tira, $root );

# --- force the SECOND removal in the plan to fail -----------------------------
#
# mid2's own directory is replaced by a plain file, so opendir on it dies the
# same way a real permission fault would - column_remove's own refusal for a
# column it cannot read. mid1 is removed first (the board's own column
# order, both missing from the new plan below), so by the time mid2 fails,
# mid1's card has already been moved to discard - the exact partial state
# this card is about.

my $mid2_dir = File::Spec->catdir( $root, '.tira', 'ticket', 'mid2' );
rmdir $mid2_dir or die "setup: could not remove mid2: $!";
open my $fh, '>', $mid2_dir or die "setup: could not create blocking file: $!";
close $fh;

my $refused = !eval {
    $tira->column_apply(
        project => $root, type => 'ticket',
        columns => [ { name => 'backlog' }, { name => 'done' }, { name => 'discard' } ],
    );
    1;
};
ok( $refused, 'a layout that would fail partway through is refused rather than half-applied' )
  or diag('column_apply silently succeeded despite the forced failure');

# --- and nothing was left half-done -------------------------------------------

is_deeply( names( $tira, $root ), $before,
    'THE BOARD LAYOUT IS EXACTLY WHAT IT WAS - not the old layout with mid1 '
      . 'already gone and not the new one either' );

my $after_one = $tira->record_show( project => $root, ref => $one->{ref} );
is( $after_one->{column}, 'mid1',
    "THE CARD ALREADY MOVED IS MOVED BACK - mid1's removal succeeded before "
      . "mid2's failed, and rolling back the decision (not a half-done "
      . 'filesystem state) is what column_remove\'s own single-column path '
      . 'already promises' );

unlink $mid2_dir;
mkdir $mid2_dir;

# --- and a layout that succeeds still applies everything as one outcome -------

my $applied = $tira->column_apply(
    project => $root, type => 'ticket',
    columns => [
        { name => 'backlog' }, { name => 'mid1', label => 'Middle' },
        { name => 'done' }, { name => 'discard' },
    ],
);
is_deeply( [ sort @{ $applied->{removed} } ], ['mid2'], 'the successful layout removed mid2' );
is_deeply( names( $tira, $root ), [qw(backlog mid1 done discard)],
    'and applied every other part of the plan in the same outcome' );

# --- column_remove on its own, outside column_apply, is unaffected -----------

my $engine = Suite::engine_source();
like( $engine, qr/sub column_remove\b.{0,1200}?_with_project_lock/s,
    'column_remove still takes its own lock when called on its own - this '
      . "card's fix is column_apply's own removal loop, not a change to the "
      . 'single-column path' );

done_testing();

__END__

=head1 NAME

548-a-layout-half-applied.t - column_apply left a half-old, half-new layout when a removal partway through failed

=head1 WHY

TKT-767. Each removal in column_apply's own loop took its own project lock
and the rest of the layout was a separate transaction after it - so a
failure partway through several removals left some columns gone (their
cards already discarded) and the rest of the intended layout, including
label/order/notify_after/watched changes and new columns, never attempted.

=head1 WHAT IS ASSERTED

That a layout which would fail partway through is refused with the board
left exactly as it was - the already-removed column's cards moved back,
not merely stopped where they were - and that a layout which succeeds
still applies every part of the plan as one outcome. Also that
C<column_remove> called on its own is unaffected.

=cut
