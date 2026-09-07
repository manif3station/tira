#!/usr/bin/env perl
# TKT-992, his report on developer-dashboard. _record_data's own per-pass path
# cache (TKT-978) resolves a ref's path once and remembers it for the rest of
# the pass - correctly, since a card's path cannot change while a pass runs.
# But it CAN change WHILE ONE IS RUNNING: a card moved between two columns by
# an agent working alongside the police loop leaves the cache pointing at a
# file that no longer exists there. Measured on his board: a move stamped
# 08:52:46, a card-unreadable line at 08:52:48 ("Cannot read JSON
# '.../ticket/vulnerability-scan/DD-813.json': No such file or directory"),
# settled next pass at 08:53:28 once the cache had expired with the pass.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-07T08:52:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Racing', dir => $root, members => ['claude'],
    columns => ['backlog, vulnerability-scan, unit-test'],
    sow_prefix => 'RCS', epic_prefix => 'RCE', ticket_prefix => 'RCT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'DD-813' );
$tira->record_move( author => 'claude', project => $root,
    ref => $card->{ref}, column => 'vulnerability-scan' );

$tira->_police_path_cache( sub {

    # Cache the ref's CURRENT path, exactly as the first rule to touch this
    # card in a pass would.
    my ( $cached_path ) = $tira->_record_data( project => $root, ref => $card->{ref} );
    like( $cached_path, qr{vulnerability-scan}, 'the cached path is the pre-move column' );

    # An agent moves the card mid-pass - the race his report measured.
    $tira->record_move( author => 'claude', project => $root,
        ref => $card->{ref}, column => 'unit-test' );

    # A later rule in the SAME pass asks for this card again. The cached path
    # is now stale; the fix re-resolves on ENOENT rather than reporting
    # card-unreadable for a card that only moved.
    my ( $path, $record ) = eval { $tira->_record_data( project => $root, ref => $card->{ref} ) };
    ok( !$@, 'a card moved mid-pass is not reported unreadable' ) or diag($@);
    like( $path // '', qr{unit-test}, 're-resolved to the card\'s new, current path' );
    is( $record->{ref}, $card->{ref}, 'and the record itself reads correctly' );
} );

# --- a genuinely missing card is still reported, no false negative ----------

$tira->_police_path_cache( sub {
    my $ghost = eval { $tira->_record_data( project => $root, ref => 'RCT-999' ) };
    ok( !$ghost, 'a ref that never existed is still refused' );
    like( $@, qr/not found/, 'with the same message as before' );
} );

# --- the re-resolve does not mask a card genuinely deleted mid-pass --------

{
    my $doomed = $tira->create_record( project => $root, type => 'ticket', title => 'About to vanish' );
    $tira->_police_path_cache( sub {
        my ( $cached_path ) = $tira->_record_data( project => $root, ref => $doomed->{ref} );
        unlink $cached_path or die "could not remove fixture file: $!";
        my $gone = eval { $tira->_record_data( project => $root, ref => $doomed->{ref} ) };
        ok( !$gone, 'a card genuinely removed mid-pass is still refused, not silently forgiven' );
        like( $@, qr/No such file or directory/,
            'with the original OS-level reason preserved, not the walk\'s own generic "not found"' );
    } );
}

done_testing();

__END__

=head1 NAME

601-a-card-that-moved-mid-walk.t - card-unreadable and a stale per-pass path cache

=head1 DESCRIPTION

TKT-992, his report on developer-dashboard. C<_record_data>'s per-pass path
cache (TKT-978) resolves a ref's path once and remembers it for the rest of
the pass - correct for a card being edited, since writing does not move its
file, but not for one being MOVED: an agent moving a card between columns
while the police loop runs is ordinary, and a path cached before the move
points at a file that has since relocated to a different column's directory,
reading as ENOENT for a card that was never actually unreadable.

Fixed by re-walking once on ENOENT for a path drawn from the cache, before
reporting C<card-unreadable>; only a re-walk that also finds nothing is
genuinely unreadable, and that case still preserves the original OS-level
reason rather than the walk's own generic "not found" (TKT-988's own
redaction promise), since a card genuinely deleted mid-pass is a real fault
this cannot paper over.

=cut
