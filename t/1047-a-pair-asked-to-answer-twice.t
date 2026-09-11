#!/usr/bin/env perl
# TKT-1047. The TKT-583 repeated-proof-pair sequence (one command/proof pair
# cannot answer two different required-action instructions in the same
# column, the --force escape and its reason, and the move-time reminder to
# work items one at a time) is independent of the general
# proof-required-to-mark-done concern t/317-a-done-that-proved-nothing.t
# exists to prove, and was lifted out of that file - 503 lines before this
# split - as its own concern, the same reason TKT-1041 through TKT-1046
# lifted six other files' own separable concerns the same week.
#
# The shared preamble ($tira/$root/$card and the cli() dispatcher helper) is
# duplicated from t/317 rather than shared, since each .t file is its own
# process and there is no shared-setup helper for this fixture yet. $card
# starts fresh here rather than carrying forward the required items t/317's
# earlier sections (lines 56-165 of the original) add and mark - nothing
# before line 167 moved its COLUMN, and none of those earlier items' proof
# pairs collide with the ones the TKT-583 sequence adds and checks below, so
# a fresh card is a valid isolated fixture even though it is not byte-for-
# byte the state t/317 handed this block.

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

require Tira::CLI;
sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME}   = $root;
        local $ENV{TIRA_AUTHOR} = 'claude';
        Tira::CLI->run( command => $command, tira => $tira, argv => [@argv] );
    };
    return ( $status, $out . $err );
}

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

    # This assertion used to read "a stated reason lets the same pair
    # through". It no longer does, and the change is deliberate: the owner
    # settled Q-086 with "doesn't need human to approval ... use a autogen
    # code to kind of force them to sign". A reason alone was self-approving,
    # which left the agent marking its own homework with a sentence attached.
    # The full two-step is exercised further down; here we only hold that a
    # reason by itself is not enough.
    my $reason_only = eval {
        $tira->required_item_update( author => 'claude', project => $root,
            ref => $second->{id} ? $card->{ref} : $card->{ref}, id => $second->{id}, status => 'done',
            command => ['prove -lr t'], proof => ['Files=400, Tests=8174, Result: PASS'],
            repeated_reason => 'One suite run genuinely proves both items: this one asks '
              . 'for the suite to pass and the previous one asks for no regression in it.' );
    };
    ok( !$reason_only, 'a stated reason alone does not let the pair through' );
    like( $@, qr/--repeated-confirm/,
        'it hands back a code to sign with instead' );
}

# --- TKT-583: the reason is read back, not merely typed ----------------------
#
# The owner, asked who approves a reuse: "doesn't need human to approval. the
# reason for the to feedback the actual description of the item with the
# reason put together to let the agent read it again to remind them what you
# are doing. if you confirm. use a autogen code to kind of force them to sign
# and make sure they know they are not doing thing blindly."
#
# So it is a forced read rather than an approval queue. The first attempt is
# refused and prints THIS item's own description beside the reason just
# given, with a generated code; the retry carries that code as the signature.
#
# That attacks the actual cause. The failure is inattention, not dishonesty -
# eleven items ticked off one prove run because nobody re-read what item
# eight asked for - and putting the instruction back in front of the agent at
# the moment they claim to have met it is what breaks that.
#
# The code is random and stored, never derived from the command and proof: a
# derived code is computable from what the agent already holds, so the second
# step would collapse into the first and the read would not be forced at all.

{
    my $one = $tira->required_item_add( author => 'claude', project => $root,
        ref => $card->{ref}, item => 'run the suite', status => 'pending' );
    my $two = $tira->required_item_add( author => 'claude', project => $root,
        ref => $card->{ref}, item => 'confirm no regression in the suite', status => 'pending' );

    $tira->required_item_update( author => 'claude', project => $root,
        ref => $card->{ref}, id => $one->{id}, status => 'done',
        command => ['prove -lr t'], proof => ['Tests=8185, Result: PASS'] );

    my $reason = 'The one run proves both: this item asks the suite passes, '
      . 'the other asks nothing regressed in it.';

    ok( !eval {
            $tira->required_item_update( author => 'claude', project => $root,
                ref => $card->{ref}, id => $two->{id}, status => 'done',
                command => ['prove -lr t'], proof => ['Tests=8185, Result: PASS'],
                repeated_reason => $reason );
            1;
        },
        'a reason alone no longer marks the item done - the first attempt is refused' );

    my $told = $@;
    like( $told, qr/\Qconfirm no regression in the suite\E/,
        "and the refusal reads THIS item's own description back to the agent" );
    like( $told, qr/\Qthe other asks nothing regressed\E/,
        'beside the reason they just gave, so the two can be compared' );

    my ($code) = $told =~ /--repeated-confirm\s+(\S+)/;
    ok( $code, 'and issues a code to sign with' );

    ok( !eval {
            $tira->required_item_update( author => 'claude', project => $root,
                ref => $card->{ref}, id => $two->{id}, status => 'done',
                command => ['prove -lr t'], proof => ['Tests=8185, Result: PASS'],
                repeated_reason => $reason, repeated_confirm => 'not-the-code' );
            1;
        },
        'a wrong code is refused' );

    my $signed = $tira->required_item_update( author => 'claude', project => $root,
        ref => $card->{ref}, id => $two->{id}, status => 'done',
        command => ['prove -lr t'], proof => ['Tests=8185, Result: PASS'],
        repeated_reason => $reason, repeated_confirm => $code );
    ok( $signed, 'the right code signs it through' );
    is( $signed->{status}, 'done', 'and the item is marked done' );
    like( $signed->{repeated_reason}, qr/proves both/, 'with the reason kept on it' );

    # Single use: the same code cannot sign a second reuse, or one read would
    # buy every future one.
    my $three = $tira->required_item_add( author => 'claude', project => $root,
        ref => $card->{ref}, item => 'a third, different instruction', status => 'pending' );
    ok( !eval {
            $tira->required_item_update( author => 'claude', project => $root,
                ref => $card->{ref}, id => $three->{id}, status => 'done',
                command => ['prove -lr t'], proof => ['Tests=8185, Result: PASS'],
                repeated_reason => $reason, repeated_confirm => $code );
            1;
        },
        'and the code is single use - it cannot sign a second reuse' );
}

# --- TKT-583: the code is bound to what it was issued for --------------------
#
# The owner: "the confirmation code is kind of key-value pair stash." The code
# is the key; what it was issued FOR is the value. Without that binding the
# forced read is not bound to the confirmation at all - a code handed out
# after showing REASON X can be redeemed while claiming REASON Y, so the agent
# reads one thing and signs another. Found by probing the first cut: it was
# accepted, and the item stored REASON Y.

{
    my $one = $tira->required_item_add( author => 'claude', project => $root,
        ref => $card->{ref}, item => 'bind one', status => 'pending' );
    my $two = $tira->required_item_add( author => 'claude', project => $root,
        ref => $card->{ref}, item => 'bind two', status => 'pending' );
    $tira->required_item_update( author => 'claude', project => $root,
        ref => $card->{ref}, id => $one->{id}, status => 'done',
        command => ['bind -x'], proof => ['bound output'] );

    eval {
        $tira->required_item_update( author => 'claude', project => $root,
            ref => $card->{ref}, id => $two->{id}, status => 'done',
            command => ['bind -x'], proof => ['bound output'],
            repeated_reason => 'REASON X: the first claim' );
    };
    my ($code) = $@ =~ /--repeated-confirm\s+(\S+)/;
    ok( $code, 'a code is issued for the reason that was shown' );

    ok( !eval {
            $tira->required_item_update( author => 'claude', project => $root,
                ref => $card->{ref}, id => $two->{id}, status => 'done',
                command => ['bind -x'], proof => ['bound output'],
                repeated_reason => 'REASON Y: a different claim entirely',
                repeated_confirm => $code );
            1;
        },
        'that code cannot be redeemed against a different reason' );

    # Changing the evidence is NOT a way past the binding - it stops being a
    # reuse at all, so no confirmation is owed and none is asked for. This
    # assertion first read "nor against different evidence" and expected a
    # refusal, which was wrong: different evidence duplicates nothing, and
    # refusing it would refuse honest work. The check earns its keep by
    # refusing reuse, not by refusing change.
    my $fresh = $tira->required_item_update( author => 'claude', project => $root,
        ref => $card->{ref}, id => $two->{id}, status => 'done',
        command => ['bind -x'], proof => ['different output entirely'] );
    ok( $fresh, 'different evidence needs no code at all - it duplicates nothing' );
    is( $fresh->{repeated_reason}, undef,
        'and carries no reason, so the board does not mark it as borrowed' );

    # Put the duplicate back so the binding case below is a real reuse again.
    $tira->required_item_update( author => 'claude', project => $root,
        ref => $card->{ref}, id => $two->{id}, status => 'pending' );

    # A fresh code for the positive control, rather than the one captured
    # above: the intervening updates moved the item's own pending stash on,
    # and a test that depends on state three operations back is testing the
    # test rather than the code.
    eval {
        $tira->required_item_update( author => 'claude', project => $root,
            ref => $card->{ref}, id => $two->{id}, status => 'done',
            command => ['bind -x'], proof => ['bound output'],
            repeated_reason => 'REASON X: the first claim' );
    };
    my ($current) = $@ =~ /--repeated-confirm\s+(\S+)/;
    my $signed = $tira->required_item_update( author => 'claude', project => $root,
        ref => $card->{ref}, id => $two->{id}, status => 'done',
        command => ['bind -x'], proof => ['bound output'],
        repeated_reason => 'REASON X: the first claim', repeated_confirm => $current );
    ok( $signed, 'and redeems against exactly what it was issued for' );
}

# --- TKT-583/TSK-168: the reminder at the move, not at the mark --------------
#
# Everything else on this card is detective - it refuses a reuse once it is
# attempted. This is the preventive half, and the owner placed it deliberately
# at the move: "remind the agent when the move a card into a new column. The
# reminder will be something like 'Get all the required action items first. Go
# through them 1 by 1 and provide the proof and command 1 at a time. DO NOT
# LEAVE IT AT LAST AND USE THE SAME PROOF FOR ALL REQUIRED ACTION ITEMS.'"
#
# The move is the right moment because that is when the list arrives. The
# reuse happens when an agent reaches the end of a column's work holding a
# list it never read item by item and one recent command - so the last chance
# to stop the habit is before it has anything to act on.

{
    my ( $status, $said ) = cli( 'record.move', '--ref', $card->{ref}, '--column', 'implement' );

    is( $status, 0, 'the move itself still succeeds' );
    like( $said, qr/one at a time/i,
        'and reminds the agent to work the required actions one at a time' );
    like( $said, qr/same proof/i,
        'naming the same-proof failure explicitly, which is the habit being prevented' );
}

done_testing();

__END__

=head1 NAME

t/1047-a-pair-asked-to-answer-twice.t - one proof pair cannot answer two instructions

=head1 DESCRIPTION

Split out of t/317-a-done-that-proved-nothing.t (TKT-1047), the same week
TKT-1041 through TKT-1046 lifted six other files' own separable concerns:
the owner's own report that a single command/proof pair had answered six
required-action items on TKT-555's install column, and eleven on TKT-570's
tests-red column, is the TKT-583 sequence proved here - a pair cannot
answer two different instructions in the same column, the escape from that
refusal costs a reason that is read back rather than merely typed, the
reason is bound to what it was issued for, and the reminder to work items
one at a time fires at the move rather than only after the reuse is
attempted.

=head1 SEE ALSO

L<t/317-a-done-that-proved-nothing.t>

=cut

