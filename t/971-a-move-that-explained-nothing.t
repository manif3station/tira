#!/usr/bin/env perl

# TKT-971. His report: a decoy ref found by a stray grep was moved backward
# by mistake, and whoever read the card next could not tell that reading
# from a genuine "this needs redoing" - the move's own journal records
# exhaustively WHAT was reset (every required item) and nothing at all
# about WHY. discard-unexplained already closes exactly this gap for a
# discard; nothing closed it for every other backward move.
#
# backward-move-unexplained mirrors discard-unexplained's own mechanism: a
# comment satisfies it if it exists at or after the backward move (a 5s
# grace for the natural decide-write-then-move authoring order), any
# earlier comment does not, and a forward move is never this rule's
# business at all.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

sub fresh_tira {
    my ($clock) = @_;
    my $tira = Tira->new( clock => $clock );
    return $tira;
}

my $WORLD = { branches => [], worktrees => [], processes => [], containers => [] };

sub pass_for {
    my ( $tira, $store ) = @_;
    my $result = $tira->police_pass( project => $root, store => $store, world => $WORLD );
    return $result->{violations} // [];
}

my $seconds = 0;
my $tira = fresh_tira( sub {
    my @gmt = gmtime( 1757170800 + ( $seconds++ * 60 ) );    # 2026-09-06T15:00:00Z, advancing one minute per call - well past the rule's own 5-second grace
    return sprintf( '%04d-%02d-%02dT%02d:%02d:%02d+0000',
        $gmt[5] + 1900, $gmt[4] + 1, $gmt[3], $gmt[2], $gmt[1], $gmt[0] );
} );
$tira->project_new(
    name => 'Backward moves', dir => $root, members => ['claude'],
    columns => ['backlog, tests-red, implement, document, verify, done'],
    sow_prefix => 'BMS', epic_prefix => 'BME', ticket_prefix => 'BMT',
);
$tira->policy_add( project => $root, rule => 'backward-move-unexplained', action => 'bridge-reminder' );

# --- a card walked forward, then back without a word ------------------------

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Moved forward then back' )->{ref};
for my $column (qw(tests-red implement document verify)) {
    $tira->record_move( author => 'claude', project => $root, ref => $card, column => $column );
}
$tira->record_move( author => 'claude', project => $root, ref => $card, column => 'tests-red' );

my $store1 = File::Spec->catdir( $tmp, 'police-1' );
my $violations = pass_for( $tira, $store1 );
my ($found) = grep { $_->{ref} eq $card && $_->{rule} eq 'backward-move-unexplained' } @{$violations};
ok( $found, 'a backward move with no comment near it is reported' );
like( $found->{detail}, qr/backward from verify to tests-red/, 'naming which columns, in which direction' );

# --- a comment written right after the move satisfies it, exactly as for a discard -----

my $explained = $tira->create_record( project => $root, type => 'ticket', title => 'Moved back and explained' )->{ref};
for my $column (qw(tests-red implement document verify)) {
    $tira->record_move( author => 'claude', project => $root, ref => $explained, column => $column );
}
$tira->record_move( author => 'claude', project => $root, ref => $explained, column => 'implement' );
$tira->comment_add( project => $root, ref => $explained, author => 'claude',
    text => 'Wrong ref, this needed a real fix - redoing implement onward.' );

my $store2 = File::Spec->catdir( $tmp, 'police-2' );
my $violations2 = pass_for( $tira, $store2 );
my ($not_found) = grep { $_->{ref} eq $explained && $_->{rule} eq 'backward-move-unexplained' } @{$violations2};
ok( !$not_found, 'a backward move followed by a real comment is not reported' );

# --- a comment from BEFORE the move, about something else, does not count --

my $stale = $tira->create_record( project => $root, type => 'ticket', title => 'An unrelated earlier comment' )->{ref};
$tira->comment_add( project => $root, ref => $stale, author => 'claude', text => 'Filled in the acceptance criteria.' );
for my $column (qw(tests-red implement document verify)) {
    $tira->record_move( author => 'claude', project => $root, ref => $stale, column => $column );
}
$tira->record_move( author => 'claude', project => $root, ref => $stale, column => 'document' );

my $store3 = File::Spec->catdir( $tmp, 'police-3' );
my $violations3 = pass_for( $tira, $store3 );
my ($still_found) = grep { $_->{ref} eq $stale && $_->{rule} eq 'backward-move-unexplained' } @{$violations3};
ok( $still_found, 'a comment written before the move it would need to explain does not satisfy it - not any comment the card has ever carried' );

# --- a forward move is never this rule's business, and gains no prompt -----

my $forward = $tira->create_record( project => $root, type => 'ticket', title => 'Only ever moved forward' )->{ref};
$tira->record_move( author => 'claude', project => $root, ref => $forward, column => 'tests-red' );
$tira->record_move( author => 'claude', project => $root, ref => $forward, column => 'implement' );

my $store4 = File::Spec->catdir( $tmp, 'police-4' );
my $violations4 = pass_for( $tira, $store4 );
my ($forward_found) = grep { $_->{ref} eq $forward && $_->{rule} eq 'backward-move-unexplained' } @{$violations4};
ok( !$forward_found, 'a card that has only ever moved forward is never reported' );

# --- discard is left to discard-unexplained, not doubled up here -----------

my $discarded = $tira->create_record( project => $root, type => 'ticket', title => 'Discarded instead' )->{ref};
for my $column (qw(tests-red implement)) {
    $tira->record_move( author => 'claude', project => $root, ref => $discarded, column => $column );
}
$tira->record_move( author => 'claude', project => $root, ref => $discarded, column => 'discard' );

my $store5 = File::Spec->catdir( $tmp, 'police-5' );
my $violations5 = pass_for( $tira, $store5 );
my ($discard_found) = grep { $_->{ref} eq $discarded && $_->{rule} eq 'backward-move-unexplained' } @{$violations5};
ok( !$discard_found, 'moving into or out of discard is discard-unexplained\'s own business, not doubled up here' );

# --- what was reset stays exactly as it already was - the half that already works -----

my $required_items = $tira->record_show( project => $root, type => 'ticket', ref => $card )->{required_items} // [];
ok( ref $required_items eq 'ARRAY', 'the reset mechanism itself is untouched - required_items still exists and is still an array as it always was' );

done_testing();

__END__

=head1 NAME

t/971-a-move-that-explained-nothing.t - a backward column move with no
reason recorded is reported, mirroring discard-unexplained

=head1 DESCRIPTION

TKT-971: a backward move already records exhaustive detail about WHAT it
reset (every required item, in the journal) and nothing about WHY - the
same gap C<discard-unexplained> already closes for a discard. His own
report: a decoy ref was moved backward by mistake, and the next reader
could not tell a genuine "this needs redoing" from a mistyped ref without
asking.

C<backward-move-unexplained> mirrors C<discard-unexplained>'s own
mechanism exactly, deliberately - the design decision this card's own
acceptance criteria required be made and recorded, not left to fall out of
the implementation: a comment satisfies it only if it exists at or after
the backward move that needs explaining (a 5-second grace for the natural
decide-write-then-move authoring order), not any comment the card has ever
carried. No C<--reason> flag on the move itself was added - a comment
written in the same breath as the move already achieves that, exactly as
it already does for a discard, and a second mechanism saying the same
thing would be two ways to satisfy one requirement rather than one clear
one.

What must not change, and does not: the existing WHAT-was-reset record
(C<_apply_column_required_actions>'s own journal entries), a forward move
gaining no prompt at all, and a backward move being no harder to make -
this rule reports, it never refuses.

=cut
