#!/usr/bin/env perl
# discard-unexplained's (and backward-move-unexplained's) fixed 5-second
# grace window rejected a comment written a realistic-but-larger number of
# seconds before the move it explains - measured 10s between two correctly-
# ordered, back-to-back agent tool calls on TKT-735, this same session
# (a card that went straight from backlog to discard, weeks after it was
# created, with no move in between - the ordinary shape for a discard).
#
# TKT-1158's fix widens GRACE_SECONDS from 5 to 30 - a 3x safety margin over
# the one measured real gap - rather than making the check unbounded by
# authoring order: TKT-735's own card shows why an unbounded, order-based
# "since the previous transition" check cannot work here. It had no column
# move before its discard, only its own creation weeks earlier with an
# unrelated comment soon after - measuring from creation would make that
# old, unrelated comment "explain" the discard no matter how large the gap,
# which is exactly the bug TKT-638 fixed and t/448/t/451 already guard
# against. GRACE_SECONDS stays a small, bounded tolerance; TKT-1158 widens
# it and deduplicates it into one shared _comments_explain_move, so
# backward-move-unexplained no longer carries its own separate inline copy.

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
      . 'inside the widened 30-second grace window, which the old 5-second one rejected' );

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
        'backward-move-unexplained does not fire - a comment 10 seconds before the backward move explains it too, '
      . 'via the SAME shared helper discard-unexplained uses' );
}

# --- control: a comment an HOUR before a backward move is still well
#     outside the (widened, but still bounded) grace window - proves the
#     shared helper enforces the same "small tolerance, not an unbounded
#     search" discipline t/451 already proves for discard-unexplained ------

{
    my $root = File::Spec->catdir( $tmp, 'too-early' );
    my $now  = '2026-09-27T12:00:00+0100';
    my $tira = Tira->new( clock => sub {$now} );
    $tira->project_new(
        name => 'Too Early', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'implement', 'qa', 'done' ],
        sow_prefix => 'TES', epic_prefix => 'TEE', ticket_prefix => 'TET',
    );
    $tira->policy_add( project => $root, rule => 'backward-move-unexplained', action => 'bridge-reminder' );
    my $record = $tira->create_record( project => $root, type => 'ticket', title => 'An hour is not "a moment ago"' );

    $now = '2026-09-27T12:04:00+0100';
    $tira->record_move( project => $root, ref => $record->{ref}, column => 'implement', author => 'claude' );

    $now = '2026-09-27T12:05:00+0100';
    $tira->record_move( project => $root, ref => $record->{ref}, column => 'qa', author => 'claude' );

    $now = '2026-09-27T13:04:50+0100';
    $tira->comment_add( project => $root, ref => $record->{ref}, author => 'claude',
        text => 'Unrelated remark, an hour before the backward move' );

    $now = '2026-09-27T14:05:00+0100';
    $tira->record_move( project => $root, ref => $record->{ref}, column => 'implement', author => 'claude' );

    my $pass = $tira->police_pass( project => $root, store => File::Spec->catdir( $tmp, 'too-early-store' ), world => {} );
    is( scalar( grep { ( $_->{rule} // '' ) eq 'backward-move-unexplained' } @{ $pass->{violations} } ), 1,
        'a comment roughly an hour before the backward move does NOT explain it - '
      . 'the shared helper is still a small bounded tolerance (30s), not an unbounded backward search' );
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
    is( () = $body =~ /\bGRACE_SECONDS\b/g, 6,
        'exactly one GRACE_SECONDS definition, not two - the constant used to be declared '
      . 'separately inside each rule\'s own copy of this computation' );
}

done_testing;
