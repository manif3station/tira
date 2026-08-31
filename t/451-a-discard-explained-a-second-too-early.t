#!/usr/bin/env perl
# TKT-778 (TKT-777 folded in). discard-unexplained (TKT-638) requires a
# comment's created_at epoch to be >= the move-to-discard epoch, found by
# scanning the card's column-change history. Two real-world gaps:
#
#   TKT-778: the natural "decide, write, then move" authoring order writes
#   the explanation ONE SECOND BEFORE the move in 15 of 19 sampled real
#   cases across three separate discard batches - failing the strict >=
#   check by exactly that second, even though the comment genuinely
#   explains the discard.
#
#   TKT-777: a card migrated in already-discarded carries no column-change
#   history entry recording a move to discard at all. With no timestamp to
#   anchor against, the rule reads that as permanently unsatisfied rather
#   than not-applicable - no comment, however good, can ever clear it.
#
# Fixed by accepting a comment up to a small GRACE_SECONDS window before the
# move (TKT-778), and falling back to "any non-empty comment" when there is
# no move timestamp to compare against at all (TKT-777).

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );

sub tira_at {
    my ($now) = @_;
    my $tira = Tira->new( clock => sub {$now} );
    return $tira;
}

my $tira0 = tira_at('2026-08-01T00:00:00Z');
$tira0->project_new(
    name => 'Discards', dir => $root, members => ['claude'],
    columns    => [ 'backlog', 'discard' ],
    sow_prefix => 'DCS', epic_prefix => 'DCE', ticket_prefix => 'DCT',
);
$tira0->policy_add( project => $root, rule => 'discard-unexplained', action => 'log-only' );

sub hits_for {
    my ($tira, $ref) = @_;
    my $violations = $tira->policy_evaluate( project => $root );
    return grep { ( $_->{rule} // '' ) eq 'discard-unexplained' && $_->{ref} eq $ref } @{$violations};
}

# --- the TKT-778 fix: a comment written 1 second BEFORE the move clears it -

my $early = $tira0->create_record( project => $root, type => 'ticket', title => 'Explained a second early' );
my $tira_comment1 = tira_at('2026-08-12T23:02:46+0100');
$tira_comment1->comment_add( project => $root, ref => $early->{ref}, author => 'claude', text => 'duplicate of DCT-001, discarding' );
my $tira_move1 = tira_at('2026-08-12T23:02:47+0100');
$tira_move1->record_move( project => $root, ref => $early->{ref}, type => 'ticket', column => 'discard', author => 'claude' );

my $tira_check = tira_at('2026-08-12T23:03:00+0100');
$tira_check->policy_add( project => $root, rule => 'discard-unexplained', action => 'log-only' );
is( scalar hits_for( $tira_check, $early->{ref} ), 0,
    'a comment written exactly 1 second before the move (the natural explain-then-act order) satisfies the rule' );

# --- control: a comment well OUTSIDE the grace window before the move ------
# does not satisfy it - this is a small tolerance for authoring order, not
# an unbounded backward search for any prior comment.

my $too_early = $tira0->create_record( project => $root, type => 'ticket', title => 'Explained an hour early' );
my $tira_comment2 = tira_at('2026-08-12T22:00:00+0100');
$tira_comment2->comment_add( project => $root, ref => $too_early->{ref}, author => 'claude', text => 'unrelated remark, an hour before the discard' );
my $tira_move2 = tira_at('2026-08-12T23:00:00+0100');
$tira_move2->record_move( project => $root, ref => $too_early->{ref}, type => 'ticket', column => 'discard', author => 'claude' );

ok( hits_for( $tira_check, $too_early->{ref} ),
    'a comment written an hour before the move, well outside the grace window, does NOT satisfy the rule' );

# --- control: no comment at all still fires, same as before this fix ------

my $silent = $tira0->create_record( project => $root, type => 'ticket', title => 'Discarded with nothing said' );
my $tira_move3 = tira_at('2026-08-12T23:00:00+0100');
$tira_move3->record_move( project => $root, ref => $silent->{ref}, type => 'ticket', column => 'discard', author => 'claude' );

ok( hits_for( $tira_check, $silent->{ref} ), 'a card discarded with no comment at all is still flagged' );

# --- the TKT-777 fix: no column-change history at all, but a real comment -
# clears it, since there is no move timestamp to compare against.

my $migrated = $tira0->create_record( project => $root, type => 'ticket', title => 'Migrated in already discarded' );
$tira_move3->record_move( project => $root, ref => $migrated->{ref}, type => 'ticket', column => 'discard', author => 'claude' );
$tira_comment2->comment_add( project => $root, ref => $migrated->{ref}, author => 'claude', text => 'genuinely explains why this was set aside' );

# Simulate a migrated-in card: its column-change history never happened on
# this board, so truncate its own history file the way a migration that
# copies only the current record (not the journal) would leave it.
my $history_file = File::Spec->catfile( $root, '.tira', 'history', "$migrated->{ref}.jsonl" );
open my $fh, '>', $history_file or die "can't truncate $history_file: $!";
close $fh;

is( scalar hits_for( $tira_check, $migrated->{ref} ), 0,
    'a card with NO column-change history at all, but a genuine comment, satisfies the rule - '
      . 'there is no move timestamp to anchor a timing comparison against, so any real comment must be enough' );

# --- control: no history AND no comment still fires - the fallback is not -
# a blanket exemption for migrated-in cards, it still requires an actual
# explanation.

my $migrated_silent = $tira0->create_record( project => $root, type => 'ticket', title => 'Migrated in, still unexplained' );
$tira_move3->record_move( project => $root, ref => $migrated_silent->{ref}, type => 'ticket', column => 'discard', author => 'claude' );
my $history_file2 = File::Spec->catfile( $root, '.tira', 'history', "$migrated_silent->{ref}.jsonl" );
open my $fh2, '>', $history_file2 or die "can't truncate $history_file2: $!";
close $fh2;

ok( hits_for( $tira_check, $migrated_silent->{ref} ),
    'a card with no column-change history AND no comment is still flagged - the no-history fallback requires a real comment, it does not exempt migrated cards outright' );

done_testing();

__END__

=head1 NAME

t/451-a-discard-explained-a-second-too-early.t - discard-unexplained
tolerates the natural explain-then-move order and cards with no move
history

=head1 DESCRIPTION

TKT-638's discard-unexplained required a comment's timestamp to be
strictly at-or-after the move-to-discard timestamp. Two real-world gaps
in that anchor: TKT-778 measured the natural "decide, write, then move"
authoring order writing the explanation one second BEFORE the move in
most sampled real cases, failing by exactly that second; TKT-777 measured
cards migrated in already-discarded, with no column-change history at
all, for which the rule had no timestamp to compare against and treated
that as permanently unsatisfied. Fixed by accepting a comment up to a
small grace window before the move, and by falling back to "any
non-empty comment" when no move timestamp exists to anchor against.

=cut
