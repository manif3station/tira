#!/usr/bin/env perl

# A move with no --type walks a card straight through a gated column.
#
# _column_required_action_violation opens with:
#
#   my $columns = eval { $tira->column_list(%args) };
#   return undef if ref $columns ne 'ARRAY';
#
# column_list needs a concrete board type. record_move and record_show do not -
# they resolve a record by ref alone. So a caller who omits the type gets a
# move that succeeds, a column lookup that fails, and a refusal that returns
# undef meaning "nothing to refuse". The gate does not fail closed; it fails
# silent and open.
#
# Reproduced on a copy of a real board before this was written: a card was
# walked from backlog to in-review through NINE gated columns with all 75 of
# its required actions pending, and not one refusal. With --type supplied the
# same card was correctly refused at the first gate, naming all twelve unmet
# items.
#
# THE SAME FAULT WAS ALREADY FIXED ON THE OTHER PATH. The browser move
# provider, forty lines earlier in the same file, recovers the type from the
# record record_move has just returned, and its comment states the principle:
# "a caller is never required to say what the engine can already tell for
# itself" (TKT-532). The CLI path never got it.
#
# Not reachable from the shipped commands - ticket.move, epic.move and
# sow.move all carry a type from the dotted dispatch. It is reachable from
# Tira::CLI->run(command => 'record.move'), which is how tools, tests and
# embedding callers enter, and which is exactly what this file does.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-27T09:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name          => 'Failing open', dir         => $root,
    members       => ['ada'],        columns     => ['backlog, gated, next, done'],
    sow_prefix    => 'FOS',          epic_prefix => 'FOE',
    ticket_prefix => 'FOT',          author      => 'ada',
);
$tira->column_update(
    project => $root, type => 'ticket', name => 'gated', author => 'ada',
    required_action => [ 'Prove something before leaving', 'And a second thing' ],
);

sub move {
    my (%opt) = @_;
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    eval {
        Tira::CLI->run(
            command => 'record.move', tira => $tira,
            argv    => [
                ( $opt{type} ? ( '--type', 'ticket' ) : () ),
                '--ref', $opt{ref}, '--column', $opt{column},
                '--author', 'ada', '-o', 'toon',
            ],
        );
    };
    select $old;
    return ( $tira->record_show( project => $root, type => 'ticket', ref => $opt{ref} ), $said // '' );
}

# --- with a type, the gate holds --------------------------------------------
#
# The control. Without this the assertions below could pass on a board where
# the column simply has no required actions, which proves nothing at all.

my $controlled = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card moved the ordinary way', author => 'ada',
);
move( ref => $controlled->{ref}, column => 'gated', type => 1 );
my ( $after_in, undef ) = move( ref => $controlled->{ref}, column => 'next', type => 1 );
is( $after_in->{column}, 'gated',
    'with a type, a card cannot leave a gated column with its required actions unmet' );
is( scalar @{ $after_in->{required_items} // [] }, 2,
    'and it received the column template on the way in' );

# --- without a type, the same card walks straight through --------------------

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card moved without a type', author => 'ada',
);
my ( $landed, undef ) = move( ref => $card->{ref}, column => 'gated' );
is( $landed->{column}, 'gated', 'a typeless move into the gated column succeeds' );
is( scalar @{ $landed->{required_items} // [] }, 2,
    'and the column template is populated, so the gate has something to enforce' );

my ( $left, undef ) = move( ref => $card->{ref}, column => 'next' );
is( $left->{column}, 'gated',
    'and a typeless move OUT is refused just like a typed one - a gate that can be skipped by leaving an argument off is not a gate' );

my $unmet = grep { lc( $_->{status} // '' ) ne 'done' } @{ $left->{required_items} // [] };
is( $unmet, 2, 'both required actions are still outstanding, so the refusal was about them' );

# --- satisfying them releases the card, still without a type -----------------
#
# The fix must not turn a typeless move into one that can never leave. Recovering
# the type is about knowing which columns exist, not about refusing the caller.

for my $item ( @{ $left->{required_items} // [] } ) {
    $tira->required_item_update(
        project => $root, type => 'ticket', ref => $card->{ref}, id => $item->{id},
        status  => 'done', author => 'ada',
        command => [ 'the command for ' . $item->{id} ],
        proof   => [ 'the output of ' . $item->{id} ],
    );
}
my ( $released, undef ) = move( ref => $card->{ref}, column => 'next' );
is( $released->{column}, 'next',
    'once they are done the typeless move goes through - the type is recovered, not demanded' );

# --- and the refusal it prints is a command somebody can run -----------------
#
# Recovering the type for the LOOKUP is only half of it. Every refusal these
# guards write ends with the move to make instead, and that line is formatted
# from the caller's own arguments - which is where the type is missing. A
# typeless caller therefore got the gate correctly closed and then told to run
# "d2 tira..move", with an uninitialized-value warning beside it.
#
# Worth an assertion of its own because the first version of this fix passed
# every test above while still printing that: the columns came back, the gate
# held, and the only thing wrong was the sentence telling the caller what to do
# about it. A guard that refuses correctly and then misdirects has moved the
# failure rather than fixed it. Reported by codex review, 2026-08-27.

my $skipper = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card that skips a column', author => 'ada',
);
my ( $stuck, $refusal ) = move( ref => $skipper->{ref}, column => 'next' );
is( $stuck->{column}, 'backlog', 'a typeless move that skips a column is refused' );
like( $refusal, qr/\Qd2 tira.ticket.move\E/,
    'and the move it tells the caller to make instead names the type, so it can be run as printed' );
unlike( $refusal, qr/tira\.\.move/,
    'rather than the empty type the caller never supplied' );
unlike( $refusal, qr/uninitialized/i,
    'and formatting that line warns about nothing' );

# --- the helper resolves a type with no record in hand ------------------------
#
# Every caller today passes a record it has already loaded, so the branch that
# resolves the ref itself is never taken by them. It is not dead: the helper's
# contract is that the record is OPTIONAL, and a future caller may reach for
# columns without one - which is exactly the position every guard was in before
# this card. Tested directly rather than through a contrived route, because a
# test that manufactures a path nobody takes proves less than one that states
# the contract.

my $resolved = Tira::CLI::_columns_for(
    $tira,
    { project => $root, ref => $card->{ref} },
    undef,
);
is( ref $resolved, 'ARRAY',
    'the helper finds the columns from a ref alone, with no record handed to it' );
ok( ( grep { $_->{name} eq 'gated' } @{$resolved} ),
    'and it is the right board - the gated column this card actually sits in is among them' );

# A ref that resolves to nothing yields no columns. Deliberately NOT described
# as the guard failing closed: a guard that cannot list columns returns undef,
# which means "nothing to refuse", exactly as it did before this card. What
# stops such a move is the move itself failing on a record that does not exist
# - a different mechanism, and worth keeping straight, because calling this
# fail-closed would describe the very behaviour TKT-597 exists to remove.
my $unresolvable = Tira::CLI::_columns_for(
    $tira,
    { project => $root, ref => 'NOPE-999' },
    undef,
);
isnt( ref $unresolvable, 'ARRAY',
    'and a ref that resolves to nothing yields no columns rather than a partial or wrong board' );

done_testing();

__END__

=head1 NAME

t/409-a-gate-that-fails-open-when-nobody-said-the-type.t - the required-action
refusal must not be skipped when a caller omits the board type

=head1 DESCRIPTION

C<_column_required_action_violation> begins by calling C<column_list>, which
needs a concrete board type, and returns C<undef> - meaning "nothing to
refuse" - when it cannot get one. C<record_move> and C<record_show> resolve a
record by ref alone, so a typeless caller gets a move that succeeds and a gate
that never runs.

Reproduced on a copy of a real board: a card walked from backlog to in-review
through nine gated columns with 75 required actions pending and no refusal.

The browser move provider already solves this, recovering the type from the
record C<record_move> returned, under the principle recorded there as "a
caller is never required to say what the engine can already tell for itself"
(TKT-532). These assertions hold the CLI path to the same standard, and the
last one holds the fix to not overcorrecting: a typeless move whose actions
are satisfied must still go through.

=cut
