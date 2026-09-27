#!/usr/bin/env perl
# discard-unexplained's (and backward-move-unexplained's) fixed 5-second
# grace window rejected a comment written a realistic-but-larger number of
# seconds before the move it explains - measured 10s between two correctly-
# ordered, back-to-back agent tool calls on TKT-735, this same session. Any
# width tuned to look generous still eventually rejects the natural
# "decide, write, then move" authoring order once real latency exceeds it.
#
# TKT-1158's fix replaces the fixed window with an authoring-ORDER check: a
# real comment explains a move if it exists anywhere from the PREVIOUS
# transition onward, regardless of how many seconds separate it from the
# move. This also deduplicates the computation - before this fix,
# backward-move-unexplained carried its own inline copy of the same
# grace-window logic discard-unexplained's own extracted helper used
# (TKT-777/TKT-778's reasoning, copied rather than shared); both now call
# the same _comments_explain_move.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );

# --- discard-unexplained: a comment 10 seconds before the discard move ------

{
    my $root = File::Spec->catdir( $tmp, 'discard' );
    my $now  = '2026-09-27T10:00:00+0100';
    my $tira = Tira->new( clock => sub {$now} );
    $tira->project_new(
        name => 'Discard Ten Seconds', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'done', 'discard' ],
        sow_prefix => 'DTS', epic_prefix => 'DTE', ticket_prefix => 'DTT',
    );
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Superseded' );

    $now = '2026-09-27T10:00:10+0100';
    $tira->comment_add( project => $root, ref => $record->{ref}, author => 'claude',
        text => 'Setting this aside, superseded by another card' );

    $now = '2026-09-27T10:00:20+0100';
    $tira->record_move( project => $root, ref => $record->{ref}, column => 'discard', author => 'claude' );

    my $inputs = $tira->_discard_unexplained_inputs( $root, $tira->record_show(
        project => $root, ref => $record->{ref}, type => 'ticket' ) );
    ok( $inputs->{explained},
        'a comment written 10 seconds before the discard move explains it - '
      . 'authoring order, not a fixed width that this gap already exceeds (5 seconds)' );

    $tira->policy_add( project => $root, rule => 'discard-unexplained', action => 'bridge-reminder' );
    my $pass = $tira->police_pass( project => $root, store => File::Spec->catdir( $tmp, 'discard-store' ), world => {} );
    is( scalar( grep { ( $_->{rule} // '' ) eq 'discard-unexplained' } @{ $pass->{violations} } ), 0,
        'discard-unexplained does not fire - the real police pass agrees with the raw inputs' );
}

# --- backward-move-unexplained: same shape, a backward move instead --------

{
    my $root = File::Spec->catdir( $tmp, 'backward' );
    my $now  = '2026-09-27T11:00:00+0100';
    my $tira = Tira->new( clock => sub {$now} );
    $tira->project_new(
        name => 'Backward Ten Seconds', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'implement', 'qa', 'done' ],
        sow_prefix => 'BTS', epic_prefix => 'BTE', ticket_prefix => 'BTT',
    );
    $tira->policy_add( project => $root, rule => 'backward-move-unexplained', action => 'bridge-reminder' );
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Needs redoing' );

    $now = '2026-09-27T11:04:00+0100';
    $tira->record_move( project => $root, ref => $record->{ref}, column => 'implement', author => 'claude' );

    $now = '2026-09-27T11:05:00+0100';
    $tira->record_move( project => $root, ref => $record->{ref}, column => 'qa', author => 'claude' );

    $now = '2026-09-27T11:10:00+0100';
    $tira->comment_add( project => $root, ref => $record->{ref}, author => 'claude',
        text => 'Sending back - the fix does not cover the reported case' );

    $now = '2026-09-27T11:10:10+0100';
    $tira->record_move( project => $root, ref => $record->{ref}, column => 'implement', author => 'claude' );

    my $pass = $tira->police_pass( project => $root, store => File::Spec->catdir( $tmp, 'backward-store' ), world => {} );
    is( scalar( grep { ( $_->{rule} // '' ) eq 'backward-move-unexplained' } @{ $pass->{violations} } ), 0,
        'backward-move-unexplained does not fire - a comment 10 seconds before the backward move explains it too' );
}

# --- an unrelated comment from before the PREVIOUS transition still does not
#     count - order-based, not "any comment the card ever had" (TKT-638's
#     own original fix, preserved by the generalization) -------------------

{
    my $root = File::Spec->catdir( $tmp, 'unrelated' );
    my $now  = '2026-09-27T12:00:00+0100';
    my $tira = Tira->new( clock => sub {$now} );
    $tira->project_new(
        name => 'Unrelated Comment', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'implement', 'qa', 'done' ],
        sow_prefix => 'UNS', epic_prefix => 'UNE', ticket_prefix => 'UNT',
    );
    $tira->policy_add( project => $root, rule => 'backward-move-unexplained', action => 'bridge-reminder' );
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Old comment does not cover a new backward move' );

    $now = '2026-09-27T12:00:01+0100';
    $tira->comment_add( project => $root, ref => $record->{ref}, author => 'claude',
        text => 'Just a note from very early on, about something else entirely' );

    $now = '2026-09-27T12:04:00+0100';
    $tira->record_move( project => $root, ref => $record->{ref}, column => 'implement', author => 'claude' );

    $now = '2026-09-27T12:05:00+0100';
    $tira->record_move( project => $root, ref => $record->{ref}, column => 'qa', author => 'claude' );

    $now = '2026-09-27T12:10:00+0100';
    $tira->record_move( project => $root, ref => $record->{ref}, column => 'implement', author => 'claude' );

    my $pass = $tira->police_pass( project => $root, store => File::Spec->catdir( $tmp, 'unrelated-store' ), world => {} );
    is( scalar( grep { ( $_->{rule} // '' ) eq 'backward-move-unexplained' } @{ $pass->{violations} } ), 1,
        'a comment from before the PREVIOUS transition still does not explain THIS backward move - '
      . 'order-based means relative to the right boundary, not "any comment ever"' );
}

# --- the computation is shared, not duplicated: exactly one subroutine -----

{
    open my $fh, '<', 'lib/Tira.pm' or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    is( () = $body =~ /\bsub _comments_explain_move\b/g, 1,
        'exactly one definition of the shared explained-by-comment computation' );
    is( () = $body =~ /\$self->_comments_explain_move\(/g, 2,
        'called from exactly two places - discard-unexplained (via its own extracted helper) '
      . 'and backward-move-unexplained, neither carrying its own copy any more' );
}

done_testing;
