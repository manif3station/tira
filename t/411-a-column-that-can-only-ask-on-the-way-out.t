#!/usr/bin/env perl

# A column can say what a card must do before it LEAVES. It cannot say what a
# card must already have done before it may be worked here at all.
#
# _column_required_action_violation compares every item against $from - the
# column being left:
#
#   my @unmet = grep {
#       ( $_->{column} // '' ) eq $from && ...
#   } @{ $current->{required_items} // [] };
#
# Entry populates the destination column's template onto the card on the way in
# (_apply_column_required_actions), so the items ARRIVE, and then gate nothing
# until the card tries to leave again. There is no comparison anywhere in the
# move path against the column being entered.
#
# The owner asked for the other half, TSK-170: "We have exit required action
# items for each column. Do we have entry required action items?" Q-087 put the
# design question back to him - refuse the move, or accept it and mark the card
# not-ready - and he answered:
#
#   "ok, then we will need entry required action list too. Can you add that to
#   cli and browser dashboard column editor modal please? For example between
#   backlog to red-test - Ther is a item needs to be done before red-test but
#   not belongs to backlog - Verify all details in the card - So the agent will
#   need to do this before start red-test otherwise, the card cannot be move to
#   red-test and stay at backlog. The --command and --proof and
#   --repeated-reason and the confimation will be like the exit required action
#   items."
#
# So: refuse, leave the card where it was, and reuse the evidence contract that
# already exists rather than growing a second one.
#
# His example is the test. A card in backlog, a tests-red column that requires
# "Verify all details in the card" on the way IN, and a move that must not
# happen until it is marked - with the card still in backlog afterwards, not
# stranded anywhere new.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-27T19:30:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name          => 'Entry gates', dir         => $root,
    members       => ['ada'],       columns     => ['backlog, tests-red, done'],
    sow_prefix    => 'EGS',         epic_prefix => 'EGE',
    ticket_prefix => 'EGT',         author      => 'ada',
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
                '--type', 'ticket', '--ref', $opt{ref}, '--column', $opt{column},
                '--author', 'ada', '-o', 'toon',
            ],
        );
    };
    select $old;
    return ( $tira->record_show( project => $root, type => 'ticket', ref => $opt{ref} ), $said // '' );
}

# --- a column can be told what a card must have done before it may arrive ----

# Deliberately NOT "column_update did not die". An unknown argument is silently
# ignored rather than refused, so that assertion passes today and would go on
# passing if nothing were ever built - it tests the absence of an exception, not
# the presence of a feature. What it must assert is that the declaration comes
# back out again.

my $declared = eval {
    $tira->column_update(
        project => $root, type => 'ticket', name => 'tests-red', author => 'ada',
        entry_required_action => ['Verify all details in the card'],
    );
};
is_deeply( ( ref $declared eq 'HASH' ? $declared->{entry_required_actions} : undef ),
    ['Verify all details in the card'],
    'declaring an entry required action returns a column that carries it' )
  or diag( $@ ? "column_update refused it: $@" : 'column_update accepted it and kept nothing' );

my $columns = $tira->column_list( project => $root, type => 'ticket' );
my ($red) = grep { $_->{name} eq 'tests-red' } @{$columns};
is_deeply( $red->{entry_required_actions} // [], ['Verify all details in the card'],
    'and it is stored on the column, separately from the ones that gate the way out' );
is_deeply( $red->{required_actions} // [], [],
    'the exit list is untouched - the two are separate templates, not one list doing both jobs' );

# --- the move in is refused, and the card does not go anywhere ---------------

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card with details nobody checked', author => 'ada',
);
my ( $held, $refusal ) = move( ref => $card->{ref}, column => 'tests-red' );
is( $held->{column}, 'backlog',
    'a card cannot enter a column while that column\'s entry actions are unmarked - and it stays where it was' );
like( $refusal, qr/\QVerify all details in the card\E/,
    'the refusal names the item standing in the way, not just that something is' );

# --- the entry items land on the card so they can be worked from outside -----
#
# The whole point of an entry gate is that the work happens BEFORE the card
# arrives. If the items only appeared once the card was inside, there would be
# nothing to mark and the card could never get in.

my @entry_items = grep { ( $_->{column} // '' ) eq 'tests-red' } @{ $held->{required_items} // [] };
is( scalar @entry_items, 1,
    'the entry item is on the card while it is still in backlog, so it can be satisfied from outside' );

# --- marking it done, with evidence, lets the card in ------------------------

# Guarded rather than assumed: with no entry mechanism there is no item to mark,
# and calling required_item_update with an undefined id aborts the whole file -
# which would hide every assertion below it and make the red run report less
# than it knows. Each dependent section fails on its own terms instead.

if ( $entry_items[0] ) {
    $tira->required_item_update(
        project => $root, type => 'ticket', ref => $card->{ref}, id => $entry_items[0]{id},
        status  => 'done', author => 'ada',
        command => ['d2 tira.ticket.show --ref EGT-001 --full'],
        proof   => ['every field read; description, acceptance criteria and scope all present'],
    );
}
# This one PASSES today, and passes for the wrong reason: with no gate at all
# the card walks in whether anything was marked or not. It is kept, and kept
# honest by this note, because its job starts once the gate exists - it is the
# over-correction guard. A gate that refuses entry is easy; a gate that still
# refuses after its items are satisfied is the failure mode that would make the
# feature unusable, and nothing else here would catch it.
my ( $admitted, undef ) = move( ref => $card->{ref}, column => 'tests-red' );
is( $admitted->{column}, 'tests-red',
    'once the entry item is done with a command and a proof, the card is let in' );

# --- the evidence contract is the existing one, not a second one -------------
#
# The owner was explicit: "The --command and --proof and --repeated-reason and
# the confimation will be like the exit required action items." So an entry item
# must refuse --status done with no evidence, exactly as an exit item does.

# Reached the way a caller reaches it - by attempting the move that brings the
# list - rather than by asserting that every column's entry items sit on every
# card from the start. That would be a different and worse design: a board with
# entry actions on six columns would put all of them on a card that has visited
# none. The items arrive when the card tries the door.

$tira->column_update(
    project => $root, type => 'ticket', name => 'done', author => 'ada',
    entry_required_action => [ 'Say what shipped', 'Say what did not' ],
);
my ( $stopped_at_done, $done_refusal ) = move( ref => $card->{ref}, column => 'done' );
is( $stopped_at_done->{column}, 'tests-red',
    'a second column\'s entry actions hold the same card at the next door, and it stays put again' );
my @done_items = grep { ( $_->{column} // '' ) eq 'done' } @{ $stopped_at_done->{required_items} // [] };
is( scalar @done_items, 2,
    'both of that column\'s entry items are on the card, so neither is discovered one refusal at a time' );

my $bare = $done_items[0] ? eval {
    $tira->required_item_update(
        project => $root, type => 'ticket', ref => $card->{ref}, id => $done_items[0]{id},
        status  => 'done', author => 'ada',
    );
    1;
} : undef;
my $bare_error = $done_items[0] ? ( $@ // '' ) : 'no entry item exists to refuse anything';
ok( $done_items[0] && !$bare,
    'an entry item refuses --status done with no --command/--proof pair, exactly as an exit item does' );
like( $bare_error, qr/command.*proof|proof.*command/i,
    'and says so in the same words, because it is the same mechanism rather than a second one' );

# --- a column that declares nothing on entry behaves exactly as it does today -

my $third = $tira->create_record(
    project => $root, type => 'ticket', title => 'A third card', author => 'ada',
);
my ( $unimpeded, undef ) = move( ref => $third->{ref}, column => 'backlog' );
is( $unimpeded->{column}, 'backlog', 'a card created in backlog is in backlog' );

$tira->column_update(
    project => $root, type => 'ticket', name => 'tests-red', author => 'ada',
    entry_required_action => [],
);
my ( $free, undef ) = move( ref => $third->{ref}, column => 'tests-red' );
is( $free->{column}, 'tests-red',
    'a column whose entry list is empty admits a card with nothing asked of it, as it always has' );

# --- a card being sent back is not asked to qualify for where it retreats to --
#
# The card asked for this to have a STATED answer rather than an accidental one,
# and the answer is the one TKT-455 already gives for exit actions: backward is
# unconditional. A card is sent back because something is wrong, and the entry
# requirement of the column it is returning to may be exactly what it is going
# back to fix. Gating the retreat would strand it between two columns, each
# refusing it for the other's reasons.

$tira->column_update(
    project => $root, type => 'ticket', name => 'backlog', author => 'ada',
    entry_required_action => ['Something nobody has done'],
);
my ( $retreated, undef ) = move( ref => $card->{ref}, column => 'backlog' );
is( $retreated->{column}, 'backlog',
    'a backward move is not refused by the destination\'s entry actions - retreating is unconditional, as it is for exit actions' );

# --- and a retreat does not drag the destination's entry list onto the card ---
#
# The forward-only decision is observable on the card, not just in the output.
# The gate returns before it writes anything on a backward move, so backlog's
# own entry action - declared above, and never done - is not populated by a card
# coming back. Asserted this way rather than as "the refusal said nothing":
# a same-column move prints nothing whatever the code does, so a denial about
# its output would pass without the feature existing at all. t/147 caught
# exactly that here, on the first version of this block.

my @backlog_items = grep { ( $_->{column} // '' ) eq 'backlog' } @{ $retreated->{required_items} // [] };
is_deeply( [ map { $_->{item} } @backlog_items ], [],
    'a card sent back does not collect the entry actions of the column it retreated to' );

my ( $stayed, undef ) = move( ref => $retreated->{ref}, column => 'backlog' );
is( $stayed->{column}, 'backlog', 'moving a card to the column it is already in changes nothing' );
my @after_noop = grep { ( $_->{column} // '' ) eq 'backlog' } @{ $stayed->{required_items} // [] };
is_deeply( [ map { $_->{item} } @after_noop ], [],
    'and a move to the column a card already occupies writes no entry items either - no door was tried' );

# --- a list that cannot be put on the card does not open the gate ------------
#
# Found by codex review, and it is the failure this gate must never have: an
# entry action declared as an empty string is stored happily by column_update,
# refused by required_item_add, and - while the error was swallowed - left the
# card with nothing unmet, so it walked straight in past a gate that believed
# it had nothing to enforce. A gate whose bookkeeping fails must fail closed.
#
# The same swallowed-eval shape as TKT-632, which was filed against this file
# earlier the same day. Reproducing it in new code while that card was open is
# the reason this assertion exists rather than a comment promising care.

$tira->column_update(
    project => $root, type => 'ticket', name => 'done', author => 'ada',
    entry_required_action => [''],
);
my $blank_card = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card met by an empty demand', author => 'ada',
);
move( ref => $blank_card->{ref}, column => 'tests-red' );
my ( $barred, $blank_refusal ) = move( ref => $blank_card->{ref}, column => 'done' );
isnt( $barred->{column}, 'done',
    'an entry action that cannot be put on the card refuses the move rather than waving it through' );
like( $blank_refusal, qr/could not be put on the card/,
    'and says so, naming the column list as the thing to fix' );

# --- the browser path admits the card, and still records what was asked ------
#
# TKT-426's split, which this card keeps: the refusal is CLI-only, because a
# human dragging a card is not an agent skipping a gate. But the bookkeeping is
# not enforcement, and a card dragged into a column used to arrive carrying that
# column's exit actions and none of its entry ones - a card that misreports what
# was asked of it. Codex found the omission; this holds the line where the
# owner drew it.

$tira->column_update(
    project => $root, type => 'ticket', name => 'done', author => 'ada',
    entry_required_action => ['Say what shipped'],
);
my $dragged = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card somebody dragged', author => 'ada',
);
my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
# _signed_in, not author: the browser move takes its author from who is signed
# in rather than from the payload, so a person cannot move a card as somebody
# else by editing a request.
$providers{move}->( { ref => $dragged->{ref}, column => 'done', _signed_in => 'ada' } );
my $after_drag = $tira->record_show( project => $root, type => 'ticket', ref => $dragged->{ref} );
is( $after_drag->{column}, 'done',
    'a browser move is not refused by an entry action - the dashboard drag keeps the behaviour the owner asked it to keep' );
my @dragged_entry = grep {
    ( $_->{column} // '' ) eq 'done' && ( $_->{item} // '' ) eq 'Say what shipped'
} @{ $after_drag->{required_items} // [] };
is( scalar @dragged_entry, 1,
    'and the entry action is on the card afterwards, so the record says what that column asks even though nobody was stopped' );

# --- a card can be excused an entry action, the same way it can an exit one --
#
# TKT-439's exemptions are a decision on record - a card says which item does
# not apply to it and why - rather than a column quietly omitting it. An entry
# action is a required item like any other, so an exemption must release the
# card here too; if it did not, a board would have to choose between gating a
# column and ever making an exception for one card.
#
# Found by coverage rather than by thinking of it: the exemption lookup in the
# entry gate was the one statement no test reached, which meant this behaviour
# was inherited rather than verified.

$tira->column_update(
    project => $root, type => 'ticket', name => 'done', author => 'ada',
    entry_required_action => ['Something this one card need not do'],
);
my $excused = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card with a standing excuse', author => 'ada',
);
$tira->record_update(
    project => $root, type => 'ticket', ref => $excused->{ref}, author => 'ada',
    required_exempt => ['Something this one card need not do'],
    exempt_reason   => ['This card is the one that BUILDS the thing the item asks about'],
);
move( ref => $excused->{ref}, column => 'tests-red' );
my ( $let_through, undef ) = move( ref => $excused->{ref}, column => 'done' );
is( $let_through->{column}, 'done',
    'an entry action a card is exempt from does not hold it at the door' );

# --- the browser path cannot refuse, but it does not go quiet either ---------
#
# It has already moved the card and answers a dashboard with no way to show a
# refusal, so a column whose entry list could not be placed would otherwise
# leave the card claiming nothing was asked of it and nobody any the wiser. The
# failure goes to STDERR, where whoever runs the dashboard finds it in the
# server log.
#
# Codex review caught the POD promising exactly this report while the provider
# discarded the return value and answered ok - the same swallow as the CLI side,
# one layer out.

$tira->column_update(
    project => $root, type => 'ticket', name => 'done', author => 'ada',
    entry_required_action => [''],
);
my $dragged_blank = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card dragged past an empty demand', author => 'ada',
);
my $said = do {
    open my $eh, '>', \my $captured or die $!;
    local *STDERR = $eh;
    my %p = Tira::CLI::browser_providers( tira => $tira, project => $root );
    $p{move}->( { ref => $dragged_blank->{ref}, column => 'done', _signed_in => 'ada' } );
    $captured // '';
};
my $landed_anyway = $tira->record_show( project => $root, type => 'ticket', ref => $dragged_blank->{ref} );
is( $landed_anyway->{column}, 'done',
    'a browser move still lands even when the entry list cannot be placed - it does not gain a refusal it was never meant to have' );
like( $said, qr/could not be put on the card/,
    'and what could not be placed is written where whoever runs the dashboard will see it, rather than swallowed' );

done_testing();

__END__

=head1 NAME

t/411-a-column-that-can-only-ask-on-the-way-out.t - a column must be able to
require work before a card may enter, not only before it may leave

=head1 DESCRIPTION

Every required action gates the way out: the guard compares each item's column
against C<$from>, the column being left. A destination column's template is
populated onto the card on arrival and then gates nothing until the card tries
to leave again.

The owner asked for the other half (TSK-170), and Q-087 settled the design he
wanted: the move is B<refused> and the card B<stays where it was>, with the
same C<--command>/C<--proof>, C<--repeated-reason> and two-step confirmation the
exit items already carry - one evidence mechanism, not two.

His own example is the case these assertions walk: a card in C<backlog>, a
C<tests-red> column requiring "Verify all details in the card" on the way in,
and a move that must not happen until it is marked. Two properties matter as
much as the refusal itself. The entry items must land on the card while it is
still outside, or there would be nothing to mark and no way in. And a column
that declares no entry items must behave exactly as it does today.

=cut
