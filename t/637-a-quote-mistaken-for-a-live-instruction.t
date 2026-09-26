#!/usr/bin/env perl
# TKT-637. A conversation record has created_at (when the record was
# written) but nothing for when the words were actually said - so folding
# in an instruction given eighteen days ago is indistinguishable by
# timestamp from the owner acting right now, and card-changed-by-owner
# fires the same CRITICAL finding either way. conversation.add gains an
# optional --said-at; card-changed-by-owner reads the record's own newest
# conversation entry directly (rather than trusting the generic journal,
# which never carries an entry's own content) and skips reporting when
# that entry's said_at is materially older than its created_at.
#
# WRITTEN RED: no said_at field exists yet, so this reproduces against
# the pre-fix code.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-09-26T15:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'A quote mistaken for a live instruction', dir => $root, members => [ 'claude', 'michael' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'PQW', epic_prefix => 'PQE', ticket_prefix => 'PQT',
);
$tira->project_update( project => $root, agent => 'claude' );
$tira->policy_add( project => $root, rule => 'card-changed-by-owner', action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Folding in an old quote', priority => 3, assignee => 'claude' );
$tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'implement' );

sub reported {
    my ($ref) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'card-changed-by-owner' && ( !defined $ref || $_->{ref} eq $ref ) }
          @{ $pass->{violations} } ];
}

# --- THE BUG: folding in words said 18 days ago reads as a live change ----

$now = '2026-09-26T16:00:00Z';
my $entry = $tira->conversation_add(
    project => $root, ref => $card->{ref}, author => 'michael', heard => 'claude',
    said => 'Do this the other way round.', said_at => '2026-09-08T09:00:00Z' );
ok( exists $entry->{said_at}, 'the conversation entry carries a said_at field' );
is( $entry->{said_at}, '2026-09-08T09:00:00Z', 'set to the value given, distinct from created_at' );
isnt( $entry->{said_at}, $entry->{created_at}, 'and genuinely different from when the record was written' );

is_deeply( reported( $card->{ref} ), [],
    'card-changed-by-owner does NOT fire - this is a historical quote being folded in, not the owner acting now' );

# --- MUST NOT REGRESS: no said_at still fires exactly as before -----------

my $card2 = $tira->create_record( project => $root, type => 'ticket',
    title => 'A live instruction with no said_at', priority => 3, assignee => 'claude' );
$tira->record_move( author => 'claude', project => $root, ref => $card2->{ref}, column => 'implement' );
$now = '2026-09-26T17:00:00Z';
$tira->conversation_add(
    project => $root, ref => $card2->{ref}, author => 'michael', heard => 'claude',
    said => 'Change this now.' );
my $found2 = reported( $card2->{ref} );
is( scalar @{$found2}, 1, 'a conversation entry with no said_at still fires, unaffected by the fix' );
is( $found2->[0]{ref}, $card2->{ref}, 'naming the right card' );

# --- MUST NOT REGRESS: a said_at close to created_at still fires ----------

my $card3 = $tira->create_record( project => $root, type => 'ticket',
    title => 'A live instruction with a fresh said_at', priority => 3, assignee => 'claude' );
$tira->record_move( author => 'claude', project => $root, ref => $card3->{ref}, column => 'implement' );
$now = '2026-09-26T18:00:00Z';
$tira->conversation_add(
    project => $root, ref => $card3->{ref}, author => 'michael', heard => 'claude',
    said => 'Change this now, said a moment ago.', said_at => '2026-09-26T17:59:50Z' );
my $found3 = reported( $card3->{ref} );
is( scalar @{$found3}, 1, 'a said_at only 10 seconds before created_at still fires - not materially older' );
is( $found3->[0]{ref}, $card3->{ref}, 'naming the right card' );

done_testing();

__END__

=head1 NAME

637-a-quote-mistaken-for-a-live-instruction.t - card-changed-by-owner does
not mistake a historical quote for a live instruction

=head1 DESCRIPTION

TKT-637. C<conversation_add> used to carry only C<created_at> (when the
record was written), never C<said_at> (when the words were actually
said) - so a quote from eighteen days earlier and an instruction given a
minute ago were indistinguishable by timestamp, and C<card-changed-by-owner>
fired the same finding either way. C<conversation.add> now takes an
optional C<--said-at>, stored as C<said_at> on the entry.
C<card-changed-by-owner> reads the record's own newest conversation entry
directly (the generic journal never carries an entry's own content, only
C<{field => 'conversation', changed => true}>) and skips reporting when
that entry's C<said_at> is materially older (more than one hour, a
deliberately generous threshold) than its C<created_at> - a historical
quote being folded in, not the owner acting now. An entry with no
C<said_at>, or one whose C<said_at> is close to C<created_at>, is
unaffected and still fires exactly as before.

=cut
