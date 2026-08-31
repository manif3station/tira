#!/usr/bin/env perl
# TKT-538: _tasklist_find_item looked an item up by id alone, with no
# session check - so tasklist_update, tasklist_remove,
# tasklist_task_attach_add/discard, and tasklist_task_ref_link/unlink all
# operated on ANY item regardless of the caller's --session, as long as the
# id was known. TSK ids are sequential and project-wide, so this was
# trivially reachable, not merely theoretical: a completely different
# session could edit or permanently delete another session's private item.
# Found and reproduced live while investigating TKT-537 (the read-only
# version of the same gap, in search()).

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-26T02:00:00+0100' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Guarded Tasks', dir => $root,
    columns => ['Backlog, Doing'],
    sow_prefix => 'GTS', epic_prefix => 'GTE', ticket_prefix => 'GTT',
);

sub exception {
    my ($code) = @_;
    my $result = eval { $code->(); 1 };
    return $result ? undef : $@;
}

# Each assertion gets its own fresh item, so an exploit that succeeds
# (proving the bug, pre-fix) never corrupts a later, independent assertion.

{
    my $item = $tira->tasklist_add( project => $root, text => 'agent-a task, update target', session => 'agent-a' );
    like(
        exception( sub { $tira->tasklist_update( project => $root, id => $item->{id}, status => 2, session => 'agent-b' ) } ),
        qr/\ANo task '\Q$item->{id}\E'/,
        'a different session cannot update another session\'s item - refused the same as an unknown id' );
    is( $tira->tasklist_list( project => $root, session => 'agent-a' )->[0]{status}, 0,
        'and the item itself is untouched - still pending' );
}

{
    my $item = $tira->tasklist_add( project => $root, text => 'agent-a task, remove target', session => 'agent-a' );
    like(
        exception( sub { $tira->tasklist_remove( project => $root, id => $item->{id}, session => 'agent-b' ) } ),
        qr/\ANo task '\Q$item->{id}\E'/,
        'a different session cannot remove another session\'s item either' );
    ok( ( grep { $_->{id} eq $item->{id} } @{ $tira->tasklist_list( project => $root, session => 'agent-a' ) } ),
        'the item still exists, not deleted' );
}

{
    my $item = $tira->tasklist_add( project => $root, text => 'agent-a task, ref-link target', session => 'agent-a' );
    like(
        exception( sub { $tira->tasklist_task_ref_link( project => $root, id => $item->{id}, refs => ['GTT-1'], session => 'agent-b' ) } ),
        qr/\ANo task '\Q$item->{id}\E'/,
        'a different session cannot link a ref onto another session\'s item' );
}

{
    # A real card, not a bare string - TKT-682 made tasklist_task_ref_link
    # validate every ref against the board, so this fixture's own setup
    # call (unguarded, unlike the exception()-wrapped assertion below)
    # needs one that actually exists.
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'ref-unlink target' );
    my $item = $tira->tasklist_add( project => $root, text => 'agent-a task, ref-unlink target', session => 'agent-a' );
    $tira->tasklist_task_ref_link( project => $root, id => $item->{id}, refs => [ $card->{ref} ], session => 'agent-a' );
    like(
        exception( sub { $tira->tasklist_task_ref_unlink( project => $root, id => $item->{id}, refs => [ $card->{ref} ], session => 'agent-b' ) } ),
        qr/\ANo task '\Q$item->{id}\E'/,
        'a different session cannot unlink a ref from another session\'s item' );
}

{
    my $item = $tira->tasklist_add( project => $root, text => 'agent-a task, attach target', session => 'agent-a' );
    like(
        exception( sub { $tira->tasklist_task_attach_add( project => $root, id => $item->{id}, files => ['/nonexistent/path.txt'], session => 'agent-b' ) } ),
        qr/\ANo task '\Q$item->{id}\E'/,
        'a different session cannot attach a file to another session\'s item (refused before the file is even touched)' );
}

{
    my $item = $tira->tasklist_add( project => $root, text => 'agent-a task, discard target', session => 'agent-a' );
    like(
        exception( sub { $tira->tasklist_task_attach_discard( project => $root, id => $item->{id}, files => ['x.txt'], session => 'agent-b' ) } ),
        qr/\ANo task '\Q$item->{id}\E'/,
        'a different session cannot discard an attachment from another session\'s item' );
}

{
    # The item's own session can still do all of the above, unaffected.
    my $item = $tira->tasklist_add( project => $root, text => 'agent-a task, own-session control', session => 'agent-a' );
    $tira->tasklist_update( project => $root, id => $item->{id}, status => 2, session => 'agent-a' );
    my ($found) = grep { $_->{id} eq $item->{id} } @{ $tira->tasklist_list( project => $root, session => 'agent-a' ) };
    is( $found->{status}, 2, 'the item\'s own session can still update it' );
}

{
    # Shared-list (no session declared) usage is unaffected: both sides are ''.
    my $item = $tira->tasklist_add( project => $root, text => 'shared item, no session' );
    $tira->tasklist_update( project => $root, id => $item->{id}, status => 1 );
    my ($found) = grep { $_->{id} eq $item->{id} } @{ $tira->tasklist_list( project => $root ) };
    is( $found->{status}, 1, 'shared-session (no --session given) mutation is completely unaffected' );
}

done_testing;

__END__

=head1 NAME

397-a-list-that-was-not-yours-to-touch.t - tasklist mutation commands enforce session ownership

=head1 DESCRIPTION

TKT-538: _tasklist_find_item resolved an item by id alone, so
tasklist_update, tasklist_remove, tasklist_task_attach_add/discard, and
tasklist_task_ref_link/unlink could all mutate or delete an item belonging
to a completely different --session, as long as the (sequential,
project-wide) id was known. This proves every mutating command now refuses
with the same "No task" error a nonexistent id would get, while the
item's own session and shared (session-less) usage remain unaffected.
Each assertion uses its own fresh item so an exploit that succeeds
(proving the bug, pre-fix) never corrupts a later, independent assertion.

=cut
