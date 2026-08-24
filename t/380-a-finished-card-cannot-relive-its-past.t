#!/usr/bin/env perl
# TKT-284: column-skipped fires for ever on work that finished before the
# policy existed, or by a legitimate shortcut nobody can undo - the ONLY
# remedy was to walk the finished card backward and forward through the
# missed column, which writes moves into its history that never happened.
# The same shape 2.35 already fixed for orphan-card, unfixed for this rule.
#
# Q-068 answered (2026-08-24): "C) Both - comment-settles now, scope-to-
# post-policy as a larger follow-up ticket." This covers the comment-settles
# half, reusing discard-unexplained's own settle check (any comment on the
# card settles it) rather than inventing a second convention.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-14T13:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Settled', dir => $root, members => ['claude'],
    columns => ['backlog, tests-red, implement, verify, document, push, done'],
    sow_prefix => 'STS', epic_prefix => 'STE', ticket_prefix => 'STT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

sub skipped {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq 'column-skipped' } @{ $pass->{violations} } ];
}

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Finished the short way' );
for my $column (qw(implement done)) {
    $now =~ s/T(\d\d):(\d\d)/sprintf 'T%02d:%02d', $1, $2 + 1/e;
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => $column );
}

$tira->policy_add( project => $root, rule => 'column-skipped', enter => 'done',
    require => 'tests-red, implement, verify, document, push', action => 'bridge-reminder' );

# --- the finding reports, exactly as it does today -------------------------
my @found = @{ skipped() };
is( scalar @found, 1, 'the card that skipped tests-red is reported' );
like( $found[0]{detail}, qr/tests-red/, 'and the finding names what was missed' );

my $before_history = $tira->record_show( project => $root, ref => $card->{ref} )->{_mtime};

# --- a comment settles it, the same shape discard-unexplained already has --
$tira->comment_add( project => $root, ref => $card->{ref}, author => 'claude',
    text => 'Finished before this policy existed - acknowledging, not rewriting the journey.' );

is( scalar @{ skipped() }, 0, 'a comment on the card settles the finding' );

# --- and settling it never wrote a move into the card's own history --------
my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
my @moves = grep { ( $_->{field} // '' ) eq 'column' }
  @{ $tira->_police_history( $root, $card->{ref}, {} ) };
is( scalar @moves, 3, 'settling the finding added no move to the card\'s history - still just the real ones (creation, then the two real moves)' );
is_deeply( [ map { $_->{after} } @moves ], [ 'backlog', 'implement', 'done' ],
    'and they are still the moves that actually happened, in the order they happened' );

# --- a card with no comment at all is still reported, as before ------------
my $noisy = $tira->create_record( project => $root, type => 'ticket', title => 'Also finished the short way' );
for my $column (qw(implement done)) {
    $now =~ s/T(\d\d):(\d\d)/sprintf 'T%02d:%02d', $1, $2 + 1/e;
    $tira->record_move( author => 'claude', project => $root, ref => $noisy->{ref}, column => $column );
}
my @still = grep { $_->{ref} eq $noisy->{ref} } @{ skipped() };
is( scalar @still, 1, 'a card with the same shortcut and no comment is still reported' );

done_testing;

__END__

=head1 NAME

380-a-finished-card-cannot-relive-its-past.t - column-skipped settles by comment, not by rewriting history

=head1 DESCRIPTION

column-skipped's only remedy used to be walking a finished card backward
and forward through the column it missed - which writes moves into the
work log that never happened, the same falsified-history shape TKT-366
already flagged as unacceptable and 2.35 already fixed for orphan-card.
TKT-284 (Q-068: comment-settles now) reuses discard-unexplained's own
settle check: any comment on the card settles the finding, with no move
written and no history rewritten. A card with the same shortcut and no
comment is still reported, exactly as before.
