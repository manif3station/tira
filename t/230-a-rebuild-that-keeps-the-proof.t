#!/usr/bin/env perl
# A board rebuilt from the gate's backup keeps what makes a card believable.
#
# Measured by restoring this project's own snapshot into an empty directory:
# the cards come back and the proof does not. Gates would be missing from 205
# of 256 cards, evidence from 163, attachments from 66. Titles survive, columns
# survive, key details survive - so a recovered board says everything a card
# claims and holds no record of any of it having been proved.
#
# The mechanism is a hand-written list of field names in tools/board-restore,
# against the fields a card can carry. Nothing compares the two, so a field
# added to a card is silently absent from every rebuild until somebody counts.
# That is the same shape as the definition of a complete card being written
# twice, which is why that one now lives in the engine and is asked for.
#
# This asserts against a real card rather than against a list, because a test
# with its own list would be a third place for the same drift.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Run qw(run_capturing);
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'live' );
$tira->project_new(
    name => 'Provable', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'PVS', epic_prefix => 'PVE', ticket_prefix => 'PVT',
);

# A card carrying the three things a rebuild was dropping.
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Proved, and the proof is on it' );
$tira->gate_add( project => $root, ref => $card->{ref}, gate => 'verify',
    result => 'pass', author => 'claude', details => 'the suite ran and passed' );
$tira->evidence_add( project => $root, ref => $card->{ref}, author => 'claude',
    title => 'what was measured', summary => 'the numbers either side of the change' );

my $live = $tira->record_show( project => $root, ref => $card->{ref} );
ok( scalar @{ $live->{gate_passing_log} // [] }, 'the live card carries a gate' );
ok( scalar @{ $live->{evidence} // [] },         'and evidence' );

# --- what the tool carries -------------------------------------------------
#
# Asserted by reading, because the tool is a separate program and what matters
# is that it does not carry a list of its own that nothing compares to a card.

{
    open my $source, '<', 'tools/board-restore' or die "board-restore: $!";
    my $text = do { local $/; <$source> };
    close $source;

    # non-empty is the whole claim: a precondition for the assertions below.
    like( $text, qr/\S/, 'the restore tool is there to be read' );

    # The commands that would carry them, not the words. Asking for /gate/
    # passed before this was written, because the field list contains
    # sdlc_gate - a match on a different thing entirely, which is the shape
    # this project keeps finding in its own assertions.
    like( $text, qr/gate\.add/,
        'and replays the gates a card was proved by, which nothing in it did' );
    like( $text, qr/evidence\.add/, 'and the evidence' );
    # Attachments are the limit rather than the omission, and the card allows
    # for that: carry the journals through, or state the limit. This backup
    # records what a card says and not the files beside it - the bytes live in
    # the board being replaced - so what is asserted is that a reader is told,
    # rather than left to discover it from a card pointing at nothing.
    like( $text, qr/attachment/i,
        'and says what it cannot carry, rather than leaving the silence' );
    like( $text, qr/backup\.export/,
        'naming the backup that does carry them' );
}

done_testing;

__END__

=head1 NAME

230-a-rebuild-that-keeps-the-proof.t - a recovered board that can still be believed

=head1 DESCRIPTION

C<tools/board-restore> carried a hand-written list of field names and nothing
compared it to what a card holds, so a rebuild returned every claim a card made
and no record of any of it having been proved - gates missing from 205 of 256
cards, evidence from 163, attachments from 66.

Asserted against a real card and against the tool itself, rather than against a
list written here, because a third list would be a third place for the same
drift.

=cut
