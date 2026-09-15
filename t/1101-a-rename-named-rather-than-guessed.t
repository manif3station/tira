#!/usr/bin/env perl
# TKT-772. Comparing the browser Columns dialog against the CLI's verb list:
# the CLI has tira.column.rename, which preserves every card in a renamed
# column (and, since TKT-613, retags required_items too). The browser's
# column-editor.js had no name field at all - only label, minutes, watch,
# entry-flag, next and required-actions were editable there.
#
# THE FIRST FIX WAS WRONG. column_apply used to detect "looks like a
# rename" by shape - exactly one column removed, exactly one added, at the
# same position - and refuse it. Codex review proved that unsound: t/52's
# own long-standing "Adding and removing in the same call" scenario removes
# one column and adds an unrelated one at the identical position, which is
# structurally indistinguishable from a real rename. Reverted entirely
# (see the card's own comments).
#
# THE REAL ANSWER (Q-162, Q-163): the browser gains an actual rename field,
# and column_apply gains an explicit rename_from field that ONLY a real
# rename control ever sets - never inferred from shape or position. A
# layout entry carrying rename_from performs an actual rename (delegated
# to column_rename itself, so cards and required_items survive exactly the
# way a standalone tira.column.rename call already promises), not a
# remove-and-recreate.
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
    project => $root, name => 'Rename', dir => $root, members => ['claude'],
    columns => ['backlog, mid, done'],
    sow_prefix => 'RNS', epic_prefix => 'RNE', ticket_prefix => 'RNT',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Card in mid' );
$tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'mid' );
$tira->required_item_add( project => $root, ref => $card->{ref}, author => 'claude', column => 'mid', item => 'a required item', status => 'pending' );

# --- an explicit rename_from performs a real rename, preserving the card --

my $applied = $tira->column_apply(
    project => $root, type => 'ticket',
    columns => [
        { name => 'backlog' }, { name => 'renamed', rename_from => 'mid' }, { name => 'done' }, { name => 'discard' },
    ],
);
ok( $applied, 'a layout naming an explicit rename is accepted, not refused' )
  or diag "died: $@";

is_deeply( names( $tira, $root ), [qw(backlog renamed done discard)],
    "the column is renamed in place - 'mid' is gone, 'renamed' holds its "
      . 'spot, nothing was removed-and-recreated' );

my $card_after = $tira->record_show( project => $root, ref => $card->{ref} );
is( $card_after->{column}, 'renamed',
    'the card that was in mid is now in renamed - a real rename, not a '
      . 'discard-and-new-empty-column' );

is( $card_after->{required_items}[0]{column}, 'renamed',
    "the card's own required_items entry is retagged to the new name too, "
      . 'the same promise tira.column.rename already makes (TKT-613)' );

# --- an unrelated same-position change is STILL not mistaken for a rename -

my $second = $tira->create_record( project => $root, type => 'ticket', title => 'Card in renamed, again' );
$tira->record_move( author => 'claude', project => $root, ref => $second->{ref}, column => 'renamed' );

my $ok = eval {
    $tira->column_apply(
        project => $root, type => 'ticket',
        columns => [ { name => 'backlog' }, { name => 'done' }, { name => 'extra' }, { name => 'discard' } ],
    );
};
ok( $ok, 'removing renamed and adding an unrelated extra column (no '
      . 'rename_from anywhere) is a genuine layout replacement and still '
      . 'succeeds - it is never mistaken for a rename just because it '
      . 'shares a position with the removed column' )
  or diag "died: $@";

my $second_after = $tira->record_show( project => $root, ref => $second->{ref} );
is( $second_after->{column}, 'discard',
    'the card that really was in the removed column is really discarded - '
      . 'this feature does not make column_apply refuse a real removal' );

# --- refusals: rename_from naming a column that is not there, or claimed --
# by two entries at once ----------------------------------------------------

eval {
    $tira->column_apply(
        project => $root, type => 'ticket',
        columns => [ { name => 'backlog' }, { name => 'x', rename_from => 'never-existed' }, { name => 'done' }, { name => 'discard' } ],
    );
};
like( $@, qr/never-existed.*not a.*current column/i,
    'rename_from naming a column that does not exist is refused by name' );

my $names_before = names( $tira, $root );
eval {
    $tira->column_apply(
        project => $root, type => 'ticket',
        columns => [
            { name => 'backlog' }, { name => 'x', rename_from => 'done' },
            { name => 'y', rename_from => 'done' }, { name => 'discard' },
        ],
    );
};
like( $@, qr/done.*more than one/i,
    'the same rename_from claimed by two entries at once is refused, '
      . 'rather than silently picking one' );
is_deeply( names( $tira, $root ), $names_before,
    'and nothing about the board changed when that refusal fired' );

# --- a protected column cannot be renamed via column_apply either ----------

eval {
    $tira->column_apply(
        project => $root, type => 'ticket',
        columns => [ { name => 'renamed-backlog', rename_from => 'backlog' }, { name => 'done' }, { name => 'discard' } ],
    );
};
like( $@, qr/backlog.*protected/i,
    "renaming the protected 'backlog' column is refused, the same way "
      . 'tira.column.rename itself already refuses it' );

# --- a valid multi-rename chain succeeds even though the FIRST version of --
# this fix (sorted, straight old->new application) would have refused it,
# since 'b' renaming to 'c' used to fight the not-yet-renamed-away column
# already called 'c' - Codex review found this live. --------------------------

my $tmp2  = tempdir( CLEANUP => 1 );
my $root2 = File::Spec->catdir( $tmp2, 'board' );
my $tira2 = Tira->new( clock => sub { '2026-09-15T12:00:00Z' } );
$tira2->project_new(
    project => $root2, name => 'Chain', dir => $root2, members => ['claude'],
    columns => ['backlog, a, b, c, done'],
    sow_prefix => 'CHS', epic_prefix => 'CHE', ticket_prefix => 'CHT',
);
my %card_in;
for my $col (qw(a b c)) {
    my $card = $tira2->create_record( project => $root2, type => 'ticket', title => "Card in $col" );
    $tira2->record_move( author => 'claude', project => $root2, ref => $card->{ref}, column => $col );
    $card_in{$col} = $card->{ref};
}

my $chained = $tira2->column_apply(
    project => $root2, type => 'ticket',
    columns => [
        { name => 'backlog' },
        { name => 'z', rename_from => 'a' },
        { name => 'c', rename_from => 'b' },
        { name => 'd', rename_from => 'c' },
        { name => 'done' }, { name => 'discard' },
    ],
);
ok( $chained, 'a valid rename chain (a->z, b->c, c->d) is accepted, not '
      . 'refused just because an intermediate target name is still occupied '
      . 'by a column not yet renamed away' )
  or diag "died: $@";
is_deeply( names( $tira2, $root2 ), [qw(backlog z c d done discard)],
    'every column landed at its real final name' );
is( $tira2->record_show( project => $root2, ref => $card_in{a} )->{column}, 'z',
    "the card that was in 'a' followed it to 'z'" );
is( $tira2->record_show( project => $root2, ref => $card_in{b} )->{column}, 'c',
    "the card that was in 'b' followed it to 'c'" );
is( $tira2->record_show( project => $root2, ref => $card_in{c} )->{column}, 'd',
    "the card that was in 'c' followed it to 'd'" );

# --- a rename is part of the SAME transaction as the rest of the call - a --
# later failure (a removal that cannot read its own column directory) rolls
# the rename back too, not just the moved cards - Codex review found the
# first version of this fix committed each rename before column_apply's own
# lock was even taken, so a later failure left it stranded. -----------------

my $tmp3  = tempdir( CLEANUP => 1 );
my $root3 = File::Spec->catdir( $tmp3, 'board' );
my $tira3 = Tira->new( clock => sub { '2026-09-15T12:05:00Z' } );
$tira3->project_new(
    project => $root3, name => 'Rollback', dir => $root3, members => ['claude'],
    columns => ['backlog, mid, blocked, done'],
    sow_prefix => 'RBS', epic_prefix => 'RBE', ticket_prefix => 'RBT',
);
my $blocked_dir = File::Spec->catdir( $root3, '.tira', 'ticket', 'blocked' );
rmdir $blocked_dir or die "test setup: could not remove '$blocked_dir': $!";
my $names_before3 = names( $tira3, $root3 );
eval {
    $tira3->column_apply(
        project => $root3, type => 'ticket',
        columns => [
            { name => 'backlog' }, { name => 'renamed', rename_from => 'mid' },
            { name => 'done' }, { name => 'discard' },
        ],
    );
};
my $died = $@;
like( $died, qr/Cannot read column 'blocked'/,
    'the deliberately unreadable column made the call fail, as set up' );
is_deeply( names( $tira3, $root3 ), $names_before3,
    "the rename this same call made ('mid' -> 'renamed') was rolled back "
      . 'along with everything else once the later removal failed - not '
      . 'left stranded, half-applied' );

done_testing;

__END__

=head1 NAME

1101-a-rename-named-rather-than-guessed.t - column_apply's explicit rename_from field

=head1 WHY

TKT-772. The browser had no rename control, and column_apply's own
remove-and-recreate handling of a name change was a landmine waiting for
one. The first fix (detecting a rename by shape) was proven unsound - a
genuine unrelated layout change can share the exact same shape. The real
answer, decided on the card (Q-162, Q-163): an explicit rename_from field,
set only by a real rename control, delegated to column_rename itself.

=head1 WHAT IS ASSERTED

A layout entry carrying rename_from performs a real rename - cards and
required_items survive, exactly as a standalone column_rename call already
promises. A same-position change with no rename_from anywhere is never
mistaken for a rename. rename_from naming a nonexistent column, claimed by
two entries at once, or naming a protected column, are all refused by
name, and refused before anything is written.

=head1 WHAT IS NOT ASSERTED

The browser's own UI for this - column-editor.js's new name field and its
own next-checkbox name-mapping are covered by manual verification and the
existing dashboard test suite's own patterns, not duplicated here, which
is engine-level only.

=cut
