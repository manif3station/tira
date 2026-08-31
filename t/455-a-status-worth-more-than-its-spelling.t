#!/usr/bin/env perl
# TKT-668. required_item_update, checklist_add and checklist_update stored
# whatever --status they were given, refusing only the empty string -
# nothing checked the value against the set the gates actually read.
# _item_is_done (lib/Tira/CLI.pm) compares lc(status) eq 'done', so a
# misspelling like 'Donee' or 'donw' silently marked an item that no gate
# will ever recognize as done: the command exits 0, the card looks
# updated, and the move-in refusal names the item as still outstanding
# for a reason nobody wrote down.
#
# required_items' declared set is {pending, done}, case-insensitive -
# the two values this codebase's own required_items ever carry.
# Checklists get the same tight vocabulary plus 'To Do' (Q-099, answered
# 2026-08-31): {pending, done, To Do}, case-insensitive - 'To Do' is
# included because it is the actual unmarked spelling this board itself
# writes on move-in, even though a required item never carries it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-08-31T12:45:00+0100'} );
$tira->project_new(
    name => 'Status', dir => $root, members => ['claude'],
    columns    => [ 'backlog', 'working' ],
    sow_prefix => 'STS', epic_prefix => 'STE', ticket_prefix => 'STT',
);

sub new_item {
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'probe' );
    $tira->required_item_add(
        project => $root, ref => $card->{ref}, type => 'ticket', column => 'working',
        item => 'do the thing', status => 'pending', author => 'claude',
    );
    my ($id) = map { $_->{id} } @{ $tira->record_show( project => $root, ref => $card->{ref} )->{required_items} };
    return ( $card, $id );
}

# --- the bug: a misspelled status is silently accepted -------------------

my ( $card1, $id1 ) = new_item();
my $ok = eval {
    $tira->required_item_update(
        project => $root, ref => $card1->{ref}, type => 'ticket', id => $id1,
        status => 'Donee', command => ['ran it'], proof => ['looked right'], author => 'claude',
    );
    1;
};
ok( !$ok, "a misspelled status ('Donee') is refused, not silently accepted - "
      . 'if this passes, the status was written and no gate will ever read it as done' );
like( $@, qr/Donee/, 'the refusal names the value that was given' );
like( $@, qr/pending|done/i, 'and names at least one value that works' );

my $unchanged = $tira->record_show( project => $root, ref => $card1->{ref} )->{required_items}->[0];
is( $unchanged->{status}, 'pending', 'the stored status is unchanged by the refused call' );

# --- control: done, in every case, still works ----------------------------

for my $spelling (qw(done Done DONE)) {
    my ( $card, $id ) = new_item();
    $tira->required_item_update(
        project => $root, ref => $card->{ref}, type => 'ticket', id => $id,
        status => $spelling, command => ['ran it'], proof => ['looked right'], author => 'claude',
    );
    my $item = $tira->record_show( project => $root, ref => $card->{ref} )->{required_items}->[0];
    is( $item->{status}, $spelling, "'$spelling' is still accepted and marks the item" );
}

# --- control: pending is a real, ordinary value, not the "unmarked" case --

my ( $card2, $id2 ) = new_item();
$tira->required_item_update( project => $root, ref => $card2->{ref}, type => 'ticket', id => $id2, status => 'pending', author => 'claude' );
my $still_pending = $tira->record_show( project => $root, ref => $card2->{ref} )->{required_items}->[0];
is( $still_pending->{status}, 'pending', "'pending' is accepted (it is a real value, not just the absence of one)" );

# --- control: a legacy record carrying a free-text status the new -------
# validation would refuse on WRITE can still be READ and the card MOVED -
# the validation is at the point of writing, not a retroactive migration.

my $card3 = $tira->create_record( project => $root, type => 'ticket', title => 'legacy' );
$tira->required_item_add(
    project => $root, ref => $card3->{ref}, type => 'ticket', column => 'working',
    item => 'legacy item', status => 'in progress', author => 'claude',
);
my $legacy = $tira->record_show( project => $root, ref => $card3->{ref} )->{required_items}->[0];
is( $legacy->{status}, 'in progress', "a legacy free-text status written before this fix reads back unchanged" );
ok( eval { $tira->record_move( project => $root, ref => $card3->{ref}, type => 'ticket', column => 'working', author => 'claude' ); 1 },
    'and the card carrying it can still be moved - the validation does not strand pre-existing data' );

# =========================================================================
# checklist_add / checklist_update - Q-099's answered half
# =========================================================================

# --- the bug: a misspelled status is silently accepted at ADD time -------

my $card4 = $tira->create_record( project => $root, type => 'ticket', title => 'checklist probe' );
$ok = eval {
    $tira->checklist_add( project => $root, ref => $card4->{ref}, item => 'do the thing',
        status => 'Donee', author => 'claude' );
    1;
};
ok( !$ok, "checklist_add refuses a misspelled status ('Donee'), not silently accepting it" );
like( $@, qr/Donee/, 'naming the value that was given' );
like( $@, qr/pending|done|To Do/i, 'and naming at least one value that works' );
is( scalar @{ $tira->record_show( project => $root, ref => $card4->{ref} )->{checklist} }, 0,
    'no item was created by the refused call' );

# --- the bug, again: a misspelled status is silently accepted at UPDATE --

my $chk = $tira->checklist_add( project => $root, ref => $card4->{ref}, item => 'do the thing',
    status => 'pending', author => 'claude' );
$ok = eval {
    $tira->checklist_update( project => $root, ref => $card4->{ref}, id => $chk->{id},
        status => 'donw', author => 'claude' );
    1;
};
ok( !$ok, "checklist_update refuses a misspelled status ('donw')" );
like( $@, qr/donw/, 'naming it' );
my $chk_unchanged = $tira->record_show( project => $root, ref => $card4->{ref} )->{checklist}->[0];
is( $chk_unchanged->{status}, 'pending', 'the stored status is unchanged by the refused update' );

# --- control: pending, done, and To Do all work, in every case -----------

for my $spelling (qw(pending done Done DONE), 'To Do', 'to do', 'TO DO') {
    my $is_done = lc($spelling) eq 'done';
    my $card = $tira->create_record( project => $root, type => 'ticket', title => "checklist $spelling" );
    my $item = $tira->checklist_add( project => $root, ref => $card->{ref}, item => 'x',
        status => $spelling, author => 'claude' );
    is( $item->{status}, $spelling, "checklist_add accepts '$spelling'" );
    $tira->checklist_update( project => $root, ref => $card->{ref}, id => $item->{id},
        status => $spelling, author => 'claude',
        ( $is_done ? ( command => ['ran it'], proof => ['looked right'] ) : () ) );
    my $updated = $tira->record_show( project => $root, ref => $card->{ref} )->{checklist}->[0];
    is( $updated->{status}, $spelling, "checklist_update accepts '$spelling'" );
}

# --- control: a legacy free-text checklist status can still be read and --
# the card moved - same non-retroactive guarantee as required_items above.
# checklist_add is validated too (unlike required_item_add, which never
# was), so a pre-fix record is simulated by writing the field directly
# rather than through the now-validating command - the same as data
# genuinely written before this fix shipped.

my $card5 = $tira->create_record( project => $root, type => 'ticket', title => 'legacy checklist' );
{
    my ( $path, $data ) = $tira->_record_data( project => $root, ref => $card5->{ref} );
    push @{ $data->{checklist} }, {
        id => 'CHK-001', item => 'legacy item', status => 'in progress',
        created_at => '2026-08-01T00:00:00+0100', last_updated => '2026-08-01T00:00:00+0100',
    };
    $tira->_write_json( $path, $data );
}
my $legacy_chk = $tira->record_show( project => $root, ref => $card5->{ref} )->{checklist}->[0];
is( $legacy_chk->{status}, 'in progress', 'a legacy free-text checklist status reads back unchanged' );
ok( eval { $tira->record_move( project => $root, ref => $card5->{ref}, type => 'ticket', column => 'working', author => 'claude' ); 1 },
    'and the card carrying it can still be moved' );

done_testing;

__END__

=head1 NAME

t/455-a-status-worth-more-than-its-spelling.t - required_item_update and
checklist_add/checklist_update refuse a status no gate can read

=head1 DESCRIPTION

required_item_update, checklist_add, and checklist_update stored any
non-empty C<--status>, so a misspelling of "done" (C<Donee>, C<donw>,
...) silently marked an item that C<_item_is_done>'s
C<lc(status) eq 'done'> comparison would never recognize - the command
exited 0, and the gate refused the move later for a reason it never
named.

Fixed by validating C<--status> against a declared set per kind (Q-099,
answered by the owner 2026-08-31): required actions get
C<{pending, done}>, case-insensitive, on C<required_item_update> only -
C<required_item_add> is deliberately left unvalidated, since every real
creation path (column templates, move-in population, a manual backfill)
writes C<pending> itself, so the misspelling this fix targets only ever
reached the board through an update. Checklists get the same tight
vocabulary plus C<To Do> - C<{pending, done, To Do}> - on both
C<checklist_add> and C<checklist_update>, since a checklist item (unlike
a required item) is commonly created directly with a caller-chosen
status.

Reading and moving a card whose items already carry an older free-text
status (written before this fix shipped) is unaffected - the validation
is at the point of writing, not a retroactive migration. TKT-668.

=cut
