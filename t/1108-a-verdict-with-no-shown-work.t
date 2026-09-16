#!/usr/bin/env perl
# TKT-786. Several police rules (discard-unexplained, card-duration,
# agent-still, board-still) compute their verdict from timestamps buried in
# history_list/comments/gate_passing_log, but nothing surfaces the actual
# computation - only the final violation text, or its absence. This session
# personally spent real time manually reconstructing why a card still showed
# discard-unexplained (grep .tira/history/<ref>.jsonl, compare epochs by
# hand) to confirm it was a 1-second timing edge case rather than a
# genuinely missing explanation.
#
# d2 tira.police.explain --ref REF --rule RULE runs the SAME computation the
# rule itself reads - _discard_unexplained_inputs, shared by both - and
# prints it, so a one-second edge case is visible as one rather than
# reconstructed by hand, and the explanation can never drift from the
# verdict because there is only one copy of the logic.
#
# Scoped to discard-unexplained for now (CHK-002); card-duration,
# agent-still and board-still are CHK-003's own carried-forward scope, each
# needing the specific declared policy for a card/board resolved first, the
# same way the police pass itself does - police.explain refuses those by
# name today rather than guessing at a shape for them.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );

sub run {
    my ( $tira, $root, $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => $command, tira => $tira, argv => [@argv] );
    };
    return ( $status, $out . $err );
}

# --- a card that fires discard-unexplained ------------------------------------

{
    my $root = File::Spec->catdir( $tmp, 'explained' );
    my $tira = Tira->new( clock => sub {'2026-08-30T04:31:27+0100'} );
    $tira->project_new(
        name => 'Explained', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'done', 'discard' ],
        sow_prefix => 'EXS', epic_prefix => 'EXE', ticket_prefix => 'EXT',
    );
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'No reason given' );
    $tira->record_move( project => $root, ref => $record->{ref}, type => 'ticket', column => 'discard', author => 'claude' );

    my ( undef, $json ) = run( $tira, $root, 'police.explain', '-o', 'json', '--ref', $record->{ref}, '--rule', 'discard-unexplained' );
    my $explained = eval { Cpanel::JSON::XS::decode_json($json) };
    ok( ref $explained eq 'HASH', 'police.explain answers with a structured explanation' ) or diag $json;
    is( $explained->{rule}, 'discard-unexplained', 'names the rule it explained' );
    is( $explained->{ref}, $record->{ref}, 'names the card it explained' );
    ok( defined $explained->{moved_epoch}, 'the actual move-to-discard epoch it compared against is shown' );
    is_deeply( $explained->{comments}, [], 'no comments exist yet, and it says so rather than guessing' );
    ok( !$explained->{explained}, 'the real verdict: not explained - no comment exists at all' );
}

# --- the exact 1-second edge case this ticket was filed over ------------------

{
    my $root = File::Spec->catdir( $tmp, 'edge' );
    my $tira = Tira->new( clock => sub {'2026-09-15T22:39:10+0100'} );
    $tira->project_new(
        name => 'Edge', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'done', 'discard' ],
        sow_prefix => 'EDS', epic_prefix => 'EDE', ticket_prefix => 'EDT',
    );
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Edge case' );
    $tira->{clock} = sub {'2026-09-15T22:39:09+0100'};
    $tira->comment_add( project => $root, ref => $record->{ref}, type => 'ticket',
        text => 'Setting this aside, superseded by another card', author => 'claude' );
    $tira->{clock} = sub {'2026-09-15T22:39:10+0100'};
    $tira->record_move( project => $root, ref => $record->{ref}, type => 'ticket', column => 'discard', author => 'claude' );

    my ( undef, $json ) = run( $tira, $root, 'police.explain', '-o', 'json', '--ref', $record->{ref}, '--rule', 'discard-unexplained' );
    my $explained = eval { Cpanel::JSON::XS::decode_json($json) };
    is( scalar @{ $explained->{comments} }, 1, 'the one comment that exists is shown, not just counted' );
    my $comment = $explained->{comments}[0];
    ok( $comment->{body_present}, 'shown as carrying a real body' );
    cmp_ok( $explained->{moved_epoch} - $comment->{epoch}, '==', 1,
        'the actual 1-second gap between the comment and the move is visible as a number, not reconstructed by hand' );
    ok( $comment->{within_grace}, 'and shown as within the grace window - GRACE_SECONDS is 5, this is 1' );
    ok( $explained->{explained}, 'the real verdict: explained - this is why discard-unexplained does not fire here' );
}

# --- a rule this command does not cover at all ---------------------------------

{
    my $root = File::Spec->catdir( $tmp, 'uncovered' );
    my $tira = Tira->new( clock => sub {'2026-09-16T00:00:00+0100'} );
    $tira->project_new(
        name => 'Uncovered', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'done' ],
        sow_prefix => 'UCS', epic_prefix => 'UCE', ticket_prefix => 'UCT',
    );
    my ( $status, $said ) = run( $tira, $root, 'police.explain', '--rule', 'orphan-card' );
    isnt( $status, 0, 'a rule this command does not cover is refused, not silently answered wrong' );
    like( $said, qr/does not cover 'orphan-card'/,
        'and says so by name, listing what it does cover rather than leaving the caller to guess' );
}

# --- card-duration (TKT-1106) --------------------------------------------------

{
    my $root = File::Spec->catdir( $tmp, 'duration' );
    my $now  = '2026-09-16T12:00:00+0100';
    my $tira = Tira->new( clock => sub {$now} );
    $tira->project_new(
        name => 'Duration', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'implement', 'done' ],
        sow_prefix => 'DUS', epic_prefix => 'DUE', ticket_prefix => 'DUT',
    );
    $tira->policy_add( project => $root, rule => 'card-duration', action => 'bridge-reminder',
        age => '1h', column => 'implement' );
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Sitting a while' );
    $now = '2026-09-16T12:05:00+0100';
    $tira->record_move( project => $root, ref => $record->{ref}, column => 'implement', author => 'claude' );
    $now = '2026-09-16T14:00:00+0100';

    my ( undef, $json ) = run( $tira, $root, 'police.explain', '-o', 'json',
        '--ref', $record->{ref}, '--rule', 'card-duration' );
    my $explained = eval { Cpanel::JSON::XS::decode_json($json) };
    ok( ref $explained eq 'HASH', 'police.explain answers card-duration too now' ) or diag $json;
    is( $explained->{watched_column}, 'implement', 'the actual column this policy watches is shown' );
    is( $explained->{since}, '2026-09-16T12:05:00+0100', 'the actual dwell-start it measured from is shown' );
    is( $explained->{age}, '1h', 'the configured threshold is shown' );
    ok( $explained->{older_than_age}, 'the real verdict: older than 1h, since it has sat there 1h55m' );
    ok( $explained->{would_fire}, 'and would_fire is true too: on the watched column, not resting, and old enough' );

    my ( undef, $missing ) = run( $tira, $root, 'police.explain', '-o', 'json', '--rule', 'card-duration' );
    like( $missing, qr/ref/i, 'and refuses without --ref, since card-duration is per-card' );
}

# --- card-duration: a discarded child must not be able to move $since -------
#
# Codex review, TKT-1106: an earlier draft passed include_discard=>1 into the
# child scan, so a child moved to discard AFTER the parent's own dwell-start
# could push $since later than the real rule (whose own $records excludes
# discard) would ever see - reporting would_fire false when the rule fires.

{
    my $root = File::Spec->catdir( $tmp, 'discarded-child' );
    my $now  = '2026-09-16T09:00:00+0100';
    my $tira = Tira->new( clock => sub {$now} );
    $tira->project_new(
        name => 'Discarded Child', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'in-progress', 'done' ],
        sow_prefix => 'DCS', epic_prefix => 'DCE', ticket_prefix => 'DCT',
    );
    $tira->policy_add( project => $root, rule => 'card-duration', action => 'bridge-reminder',
        age => '1h', column => 'in-progress' );
    my $epic = $tira->create_record( project => $root, type => 'epic', title => 'A parent' );
    $now = '2026-09-16T09:05:00+0100';
    $tira->record_move( project => $root, ref => $epic->{ref}, type => 'epic', column => 'in-progress', author => 'claude' );
    my $child = $tira->create_record( project => $root, type => 'ticket', title => 'A child',
        parent => $epic->{ref} );
    $now = '2026-09-16T13:00:00+0100';
    $tira->record_move( project => $root, ref => $child->{ref}, column => 'discard', author => 'claude' );
    $now = '2026-09-16T14:00:00+0100';

    my ( undef, $json ) = run( $tira, $root, 'police.explain', '-o', 'json',
        '--ref', $epic->{ref}, '--rule', 'card-duration' );
    my $explained = eval { Cpanel::JSON::XS::decode_json($json) };
    is( $explained->{since}, '2026-09-16T09:05:00+0100',
        'the discarded child\'s own move is NOT used to push the parent\'s dwell-start later - '
          . 'the real rule\'s own $records excludes discard, and explain must read the same set' );
    ok( $explained->{would_fire}, 'so the real verdict still fires here, 4h55m after the epic\'s own move' );
}

# --- board-still and agent-still (TKT-1106), whole-board -----------------------

{
    my $root = File::Spec->catdir( $tmp, 'whole-board' );
    my $now  = '2026-09-16T09:00:00+0100';
    my $tira = Tira->new( clock => sub {$now} );
    $tira->project_new(
        name => 'Whole Board', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'done' ],
        sow_prefix => 'WBS', epic_prefix => 'WBE', ticket_prefix => 'WBT',
    );
    $tira->policy_add( project => $root, rule => 'board-still', action => 'bridge-reminder', age => '2h' );
    $tira->policy_add( project => $root, rule => 'agent-still', action => 'bridge-reminder', age => '2h' );
    my $wb_card = $tira->create_record( project => $root, type => 'ticket', title => 'Only card on the board' );
    $now = '2026-09-16T09:15:00+0100';
    $tira->record_move( project => $root, ref => $wb_card->{ref}, column => 'done', author => 'claude' );
    $now = '2026-09-16T12:30:00+0100';

    my ( undef, $board_json ) = run( $tira, $root, 'police.explain', '-o', 'json', '--rule', 'board-still' );
    my $board = eval { Cpanel::JSON::XS::decode_json($board_json) };
    is( $board->{moved}, '2026-09-16T09:15:00+0100', 'the actual last-moved timestamp on the whole board is shown' );
    is( $board->{age}, '2h', 'the configured threshold is shown' );
    ok( $board->{older_than_age}, 'the real verdict: 3h15m of silence is older than the 2h threshold' );

    my ( undef, $agent_json ) = run( $tira, $root, 'police.explain', '-o', 'json', '--rule', 'agent-still' );
    my $agent = eval { Cpanel::JSON::XS::decode_json($agent_json) };
    is( $agent->{age}, '2h', 'agent-still\'s own threshold is shown too' );
    ok( defined $agent->{acted}, 'and when the agent last acted, not just the board-wide figure - the two rules ask different questions' );
    is_deeply( $agent->{waiting}, [], 'the only card is in done, so nothing is waiting on the agent' );
    ok( !$agent->{would_fire},
        'and would_fire is false despite older_than_age being true - the idle-queue exemption the '
          . 'real rule applies, Codex review caught the first draft missing' );

    my ( $status, $said ) = run( $tira, $root, 'police.explain', '--ref', 'WBT-001', '--rule', 'board-still' );
    isnt( $status, 0, 'board-still refuses --ref, since it is whole-board and a per-card answer would say nothing true' );
    like( $said, qr/whole-board/, 'naming why, not just refusing' );
}

# --- agent-still: a genuinely waiting card makes would_fire true too --------

{
    my $root = File::Spec->catdir( $tmp, 'waiting' );
    my $now  = '2026-09-16T09:00:00+0100';
    my $tira = Tira->new( clock => sub {$now} );
    $tira->project_new(
        name => 'Waiting', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'implement', 'done' ],
        sow_prefix => 'WAS', epic_prefix => 'WAE', ticket_prefix => 'WAT',
    );
    $tira->policy_add( project => $root, rule => 'agent-still', action => 'bridge-reminder', age => '2h' );
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Sitting in implement' );
    $now = '2026-09-16T09:15:00+0100';
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );
    $now = '2026-09-16T12:30:00+0100';

    my ( undef, $json ) = run( $tira, $root, 'police.explain', '-o', 'json', '--rule', 'agent-still' );
    my $explained = eval { Cpanel::JSON::XS::decode_json($json) };
    is_deeply( $explained->{waiting}, [ $card->{ref} ], 'the card sitting in implement is shown as waiting' );
    ok( $explained->{would_fire}, 'and would_fire is now true - something is actually waiting on the agent' );
}

# --- more than one declared policy for a whole-board rule is refused -------

{
    my $root = File::Spec->catdir( $tmp, 'ambiguous' );
    my $tira = Tira->new( clock => sub {'2026-09-16T09:00:00+0100'} );
    $tira->project_new(
        name => 'Ambiguous', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'done' ],
        sow_prefix => 'AMS', epic_prefix => 'AME', ticket_prefix => 'AMT',
    );
    $tira->policy_add( project => $root, rule => 'board-still', action => 'bridge-reminder',
        age => '2h', type => 'ticket' );
    $tira->policy_add( project => $root, rule => 'board-still', action => 'bridge-reminder',
        age => '4h', type => 'epic' );

    my ( $status, $said ) = run( $tira, $root, 'police.explain', '--rule', 'board-still' );
    isnt( $status, 0, 'two declared board-still policies is refused rather than silently explaining one of them' );
    like( $said, qr/more than one/i, 'naming why' );
}

done_testing;

__END__

=head1 NAME

1108-a-verdict-with-no-shown-work.t - tira.police.explain shows a rule's actual inputs

=head1 WHY

TKT-786: several police rules compute their verdict from timestamps buried
in history/comments, but nothing surfaced the actual computation. This
turns "why does this still fire" from manual history_list archaeology into
one command - reading the same inputs the rule itself reads
(_discard_unexplained_inputs, shared by both), so the explanation can
never drift from the verdict.

=head1 WHAT IS ASSERTED

For discard-unexplained: the actual move-to-discard epoch and every
comment's own epoch/grace-window comparison are shown, not just the final
verdict - proved against both an unexplained card and the exact 1-second
edge case that prompted this ticket. A rule this command does not yet
cover (card-duration) is refused by name rather than guessed at.

=cut
