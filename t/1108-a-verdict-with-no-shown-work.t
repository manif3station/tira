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

# --- a rule this command does not yet cover -----------------------------------

{
    my $root = File::Spec->catdir( $tmp, 'uncovered' );
    my $tira = Tira->new( clock => sub {'2026-09-16T00:00:00+0100'} );
    $tira->project_new(
        name => 'Uncovered', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'done' ],
        sow_prefix => 'UCS', epic_prefix => 'UCE', ticket_prefix => 'UCT',
    );
    my ( $status, $said ) = run( $tira, $root, 'police.explain', '--rule', 'card-duration' );
    isnt( $status, 0, 'a rule not yet covered is refused, not silently answered wrong' );
    like( $said, qr/card-duration.*follow-up|follow-up.*card-duration/is,
        'and says so by name, naming this as tracked work rather than an unknown command' );
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
