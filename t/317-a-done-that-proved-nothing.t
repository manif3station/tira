#!/usr/bin/env perl
# Marking a required item or checklist item done used to prove nothing.
#
# MEASURED on ZSD-246: an agent created 9 checklist items and marked all 9
# 'Done' inside a 5-second window - a narrative written after the work
# supposedly finished, stamped done the instant it was typed. The owner
# caught it by inspecting timestamps, and said this was the third time on
# the same ticket he had to catch a 'done' claim that was not substantively
# true when made.
#
# His fix, worked out over several messages: marking either kind of item
# done now requires at least one --command/--proof pair (repeatable - one
# item may need several commands, each with its own output). --proof is the
# literal output of --command, trusted as given rather than re-executed.
# Long proof (over 2000 chars, the same truncation threshold already used
# elsewhere on this board) is stored as an attachment instead of inlined, so
# the card is not overpopulated. Both pairs are logged to gate_passing_log,
# so what proved an item done survives independently of the item itself.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Proof', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'PFS', epic_prefix => 'PFE', ticket_prefix => 'PFT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Proved' );

# --- a required item cannot be marked done without proof --------------------------

my $req = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
    item => 'left a note', status => 'pending' );

ok( !eval {
        $tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref},
            id => $req->{id}, status => 'done' );
        1;
    },
    'marking a required item done with no proof at all refuses' );
like( $@, qr/proof/i, 'and names what is missing' );

# --- one command/proof pair is enough, and it is readable back --------------------

my $done = $tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref},
    id => $req->{id}, status => 'done',
    command => ['prove -l t/foo.t'], proof => ['ok 1 - foo\n1..1\nok'] );

is( $done->{status}, 'done', 'the update succeeds once a pair is given' );
is( scalar @{ $done->{proof} }, 1, 'and the pair is stored on the item' );
is( $done->{proof}[0]{command}, 'prove -l t/foo.t', 'naming the command run' );
is( $done->{proof}[0]{proof}, 'ok 1 - foo\n1..1\nok', 'and the output it produced' );

my $record = $tira->record_show( project => $root, ref => $card->{ref} );
my ($gate) = grep { $_->{gate} eq 'required-action' } @{ $record->{gate_passing_log} };
ok( $gate, 'the proof is also logged to gate_passing_log' );
like( $gate->{details}, qr/left a note/, 'naming the item it proved' );
like( $gate->{details}, qr/prove -l t\/foo\.t/, 'and the command that proved it' );

# --- multiple pairs on one item are all stored -------------------------------------

my $req2 = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
    item => 'two-step check', status => 'pending' );
my $multi = $tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref},
    id => $req2->{id}, status => 'done',
    command => [ 'cmd one', 'cmd two' ], proof => [ 'out one', 'out two' ] );
is( scalar @{ $multi->{proof} }, 2, 'two command/proof pairs are both stored' );
is( $multi->{proof}[1]{command}, 'cmd two', 'in the order they were given' );

# --- mismatched pair counts refuse, rather than silently pairing wrong -------------

my $req3 = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
    item => 'mismatched', status => 'pending' );
ok( !eval {
        $tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref},
            id => $req3->{id}, status => 'done',
            command => [ 'a', 'b' ], proof => ['only one'] );
        1;
    },
    'a command count that does not match the proof count refuses' );

# --- long proof becomes an attachment instead of inlining onto the card -----------

my $req4 = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
    item => 'big output', status => 'pending' );
my $long = 'x' x 2001;
my $stored = $tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref},
    id => $req4->{id}, status => 'done',
    command => ['a very chatty command'], proof => [$long] );
ok( !exists $stored->{proof}[0]{proof}, 'proof over 2000 chars is not inlined on the item' );
ok( $stored->{proof}[0]{attachment}, 'an attachment reference is stored instead' );

my $with_attachment = $tira->record_show( project => $root, ref => $card->{ref} );
ok( scalar @{ $with_attachment->{attachments} } >= 1,
    'and the content actually landed in the record\'s attachments' );

my $req5 = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
    item => 'short output', status => 'pending' );
my $short = 'x' x 2000;
my $inline = $tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref},
    id => $req5->{id}, status => 'done',
    command => ['a quiet command'], proof => [$short] );
is( $inline->{proof}[0]{proof}, $short, 'proof at exactly 2000 chars stays inline' );
ok( !$inline->{proof}[0]{attachment}, 'and carries no attachment reference' );

# --- checklist_update is gated the same way -----------------------------------------

my $chk = $tira->checklist_add( author => 'claude', project => $root, ref => $card->{ref},
    item => 'a plain checklist step', status => 'pending' );
ok( !eval {
        $tira->checklist_update( author => 'claude', project => $root, ref => $card->{ref},
            id => $chk->{id}, status => 'done' );
        1;
    },
    'checklist_update refuses done with no proof too' );

my $chk_done = $tira->checklist_update( author => 'claude', project => $root, ref => $card->{ref},
    id => $chk->{id}, status => 'done',
    command => ['ls'], proof => ['file.txt'] );
is( scalar @{ $chk_done->{proof} }, 1, 'and succeeds with a pair, stored the same way' );

# --- marking anything other than done never asks for proof ---------------------------
#
# The gate is specifically about the claim "this is done", not every status
# change - a card moved back to pending should never need to justify itself.

my $req6 = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
    item => 'never done', status => 'pending' );
my $still_pending = $tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref},
    id => $req6->{id}, status => 'pending' );
is( $still_pending->{status}, 'pending', 'setting a non-done status never requires proof' );

# --- and the internal move-triggered reset, which always sets pending, is unaffected --

$tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref},
    id => $req->{id}, status => 'pending', source => 'required-action' );
my $reset = $tira->required_item_list( project => $root, ref => $card->{ref} );
my ($reset_entry) = grep { $_->{id} eq $req->{id} } @{$reset};
is( $reset_entry->{status}, 'pending', 'the backward-move reset (always to pending) needs no proof either' );

# --- TKT-583: one pair cannot answer two different instructions --------------
#
# The owner, on his own board: "In order to move the card, the agent will use
# the same command and message to fill in and mark all done. Like TKT-555
# Install column. All required action items ran command and proof all the
# same. And that is one of many."
#
# Confirmed on both cards he pointed at, and on one of mine: TKT-555's install
# column had six items sharing one pair, and TKT-570's tests-red column had
# eleven - a single `prove` run answering instructions like "add the start
# date" and "link the related tasks", which have nothing to do with running a
# test. TKT-453 made a done claim cost evidence; it did not stop one piece of
# evidence being spent eleven times.
#
# Scoped to the column, because that is where the pattern appears and where
# the instructions differ from each other. Two items in the same column
# proved by the same command and the same output are, by construction, not
# both proved.

{
    my $one = $tira->required_item_add( author => 'claude', project => $root,
        ref => $card->{ref}, item => 'first instruction', status => 'pending' );
    my $two = $tira->required_item_add( author => 'claude', project => $root,
        ref => $card->{ref}, item => 'a different instruction', status => 'pending' );

    my $marked = $tira->required_item_update( author => 'claude', project => $root,
        ref => $card->{ref}, id => $one->{id}, status => 'done',
        command => ['prove -l t/317.t'], proof => ['All tests successful'] );
    ok( $marked, 'the first item takes the pair as it always did' );

    ok( !eval {
            $tira->required_item_update( author => 'claude', project => $root,
                ref => $card->{ref}, id => $two->{id}, status => 'done',
                command => ['prove -l t/317.t'], proof => ['All tests successful'] );
            1;
        },
        'a second item in the same column cannot reuse that identical pair' );
    like( $@, qr/\Q$one->{id}\E/,
        'and the refusal names the item already carrying it, so the reader knows where to look' );

    # Trailing whitespace must not defeat it - the same text with a newline is
    # the same evidence, and a check that a stray character can slip past is
    # not a check.
    ok( !eval {
            $tira->required_item_update( author => 'claude', project => $root,
                ref => $card->{ref}, id => $two->{id}, status => 'done',
                command => ["prove -l t/317.t\n"], proof => ["All tests successful  "] );
            1;
        },
        'and trimming means trailing whitespace does not slip the same pair through' );

    # Genuinely different evidence still works, which is the whole point: this
    # refuses reuse, not marking.
    my $ok = $tira->required_item_update( author => 'claude', project => $root,
        ref => $card->{ref}, id => $two->{id}, status => 'done',
        command => ['git diff --stat'], proof => ['2 files changed'] );
    ok( $ok, 'a different command and proof marks the second item done' );

    # And a pair may be reused for a DIFFERENT column, where the instructions
    # are a different set - the card scopes this to "this column".
    $tira->record_move( author => 'claude', project => $root,
        ref => $card->{ref}, column => 'implement' );
    my $elsewhere = $tira->required_item_add( author => 'claude', project => $root,
        ref => $card->{ref}, item => 'an instruction in another column', status => 'pending' );
    my $reused = eval {
        $tira->required_item_update( author => 'claude', project => $root,
            ref => $card->{ref}, id => $elsewhere->{id}, status => 'done',
            command => ['prove -l t/317.t'], proof => ['All tests successful'] );
    };
    ok( $reused, 'the same pair is allowed in a different column' );
}

# --- TKT-583: the escape costs a reason -------------------------------------
#
# The owner, asked whether an honest reuse should have a way through: "if the
# agent thinks using the same command and proof set for other required action
# item. in order to prevent command fail and get warning. They need to provide
# a valid reason for that. like --command foobar --proof something
# --repeated-reason 'VALID REASON. NO FUFFF.'"
#
# So the door is not locked, it is priced. Reuse is allowed when the agent
# says why, and the reason is stored on the item so the claim can be read back
# later rather than evaporating at the moment it was accepted.
#
# The reason must have content. An empty one would rebuild exactly the hole
# TKT-585 was filed for an hour earlier - a gate that counts an argument
# rather than reading it - and building that twice in one night would be
# careless.

{
    my $first = $tira->required_item_add( author => 'claude', project => $root,
        ref => $card->{ref}, item => 'one instruction', status => 'pending' );
    my $second = $tira->required_item_add( author => 'claude', project => $root,
        ref => $card->{ref}, item => 'another instruction', status => 'pending' );

    $tira->required_item_update( author => 'claude', project => $root,
        ref => $card->{ref}, id => $first->{id}, status => 'done',
        command => ['prove -lr t'], proof => ['Files=400, Tests=8174, Result: PASS'] );

    ok( !eval {
            $tira->required_item_update( author => 'claude', project => $root,
                ref => $card->{ref}, id => $second->{id}, status => 'done',
                command => ['prove -lr t'], proof => ['Files=400, Tests=8174, Result: PASS'] );
            1;
        },
        'without a reason the reuse is still refused' );
    like( $@, qr/repeated-reason/,
        'and the refusal names the escape, so the agent knows what it costs' );

    ok( !eval {
            $tira->required_item_update( author => 'claude', project => $root,
                ref => $card->{ref}, id => $second->{id}, status => 'done',
                command => ['prove -lr t'], proof => ['Files=400, Tests=8174, Result: PASS'],
                repeated_reason => '   ' );
            1;
        },
        'an empty reason does not buy the reuse - that would be TKT-585 rebuilt' );

    my $allowed = $tira->required_item_update( author => 'claude', project => $root,
        ref => $card->{ref}, id => $second->{id}, status => 'done',
        command => ['prove -lr t'], proof => ['Files=400, Tests=8174, Result: PASS'],
        repeated_reason => 'One suite run genuinely proves both items: this one asks '
          . 'for the suite to pass and the previous one asks for no regression in it.' );
    ok( $allowed, 'a stated reason lets the same pair through' );
    like( $allowed->{repeated_reason}, qr/genuinely proves both/,
        'and the reason is stored on the item, so it can be read back and judged later' );
}

done_testing;

__END__

=head1 NAME

317-a-done-that-proved-nothing.t - required_item_update and checklist_update require proof to mark done

=head1 DESCRIPTION

Caught on ZSD-246: 9 checklist items created and marked Done within a
5-second window, a narrative written after the fact rather than a live
record of progress. C<required_item_update> and C<checklist_update> now
refuse C<--status done> without at least one C<--command>/C<--proof> pair;
each pair is stored on the item and logged to C<gate_passing_log>. Proof
over 2000 characters (the truncation threshold already used elsewhere on
this board) is stored as an attachment instead of inlined. Only marking
C<done> is gated - every other status change, including the move
mechanism's own backward reset to C<pending>, is unaffected.

=cut
