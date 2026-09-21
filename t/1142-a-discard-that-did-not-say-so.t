#!/usr/bin/env perl

# TKT-1096. record_discard and record_restore are thin wrappers over
# record_move (lib/Tira.pm), which already returns previous_column for
# them too. But the CLI dispatch's confirmation-stamping - the "REF moved:
# FROM -> TO" line TKT-785 added ahead of the full record dump, so the one
# fact that confirms a move worked is not buried a hundred lines deep -
# lives only in the 'move' branch (lib/Tira/CLI.pm's record.discard/
# record.restore branches call the engine methods directly and return
# immediately, never reaching it). Found by the hourly bug hunt directly
# after TKT-785 shipped, checking whether the fix reached every command
# built on the same mechanism.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

sub run_cli {
    my ( $command, @argv ) = @_;
    my $type = $command =~ s/\A(sow|epic|ticket)\.//x ? $1 : undef;
    $command = "record.$command" if defined $type;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => $command, type => $type, argv => \@argv );
    return ( $status, $out, $err );
}

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
$ENV{TIRA_HOME} = $root;

my $tira = Tira->new( clock => sub { '2026-09-21T09:00:00Z' } );
$tira->project_new(
    name => 'DiscardSaysSo', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'DSS', epic_prefix => 'DSE', ticket_prefix => 'DST',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'A card with history' );
$tira->comment_add( project => $root, ref => $card->{ref}, author => 'claude', text => 'a comment, so the full dump is not tiny' );

# --- discard: -o human announces itself, at the START, before the dump -----

my ( $status, $out ) = run_cli( 'ticket.discard', '--ref', $card->{ref}, '--author', 'claude', '-o', 'human' );
is( $status, 0, 'the discard succeeds' );

my ($first_line) = split /\n/, $out, 2;
like( $first_line, qr/\Q$card->{ref}\E\s+(?:discarded|moved):\s*backlog\s*->\s*discard/i,
    'the FIRST line of -o human discard output names the ref, the source column and discard - not buried in a full dump' );
like( $out, qr/\Q$card->{ref}\E/,
    'the full record still follows - nothing that reads the whole output loses information' );

# --- discard: -o json carries a structured field too ------------------------

my $second = $tira->create_record( project => $root, type => 'ticket', title => 'Second card' );
$tira->comment_add( project => $root, ref => $second->{ref}, author => 'claude', text => 'duplicate of the first card' );
( $status, $out ) = run_cli( 'ticket.discard', '--ref', $second->{ref}, '--author', 'claude', '-o', 'json' );
is( $status, 0, 'the discard succeeds under -o json' );
my $decoded = decode_json($out);
like( $decoded->{moved}, qr/\Q$second->{ref}\E\s+(?:discarded|moved):\s*backlog\s*->\s*discard/i,
    '-o json carries a structured field naming both the source column and discard' );
is( $decoded->{ref}, $second->{ref}, 'and the full record is still there too, not replaced by the summary field' );
is( $decoded->{column}, 'discard', 'including the real, current column' );

# --- restore: -o human announces itself the same way ------------------------

( $status, $out ) = run_cli( 'ticket.restore', '--ref', $card->{ref}, '--author', 'claude', '--column', 'implement', '-o', 'human' );
is( $status, 0, 'the restore succeeds' );
( $first_line ) = split /\n/, $out, 2;
like( $first_line, qr/\Q$card->{ref}\E\s+(?:restored|moved):\s*discard\s*->\s*implement/i,
    'the FIRST line of -o human restore output names the ref, discard as the source, and the real destination' );

# --- restore: -o json carries the same structured field ---------------------

$tira->record_move( project => $root, ref => $second->{ref}, column => 'discard', author => 'claude' )
  if $tira->record_show( project => $root, ref => $second->{ref} )->{column} ne 'discard';
( $status, $out ) = run_cli( 'ticket.restore', '--ref', $second->{ref}, '--author', 'claude', '-o', 'json' );
is( $status, 0, 'the restore succeeds under -o json' );
$decoded = decode_json($out);
like( $decoded->{moved}, qr/\Q$second->{ref}\E\s+(?:restored|moved):\s*discard\s*->\s*backlog/i,
    '-o json carries a structured field for restore too, defaulting to backlog same as the CLI itself does' );

# --- a refused discard/restore never claims to have happened ----------------

( $status, $out, my $err ) = run_cli( 'ticket.discard', '--ref', 'DST-999', '--author', 'claude' );
isnt( $status, 0, 'discarding a nonexistent card is refused' );
unlike( $out, qr/(?:discarded|moved):/i, 'a refusal never claims a discard happened' );

# Codex review: only discard's refusal was covered above, not restore's.
( $status, $out, $err ) = run_cli( 'ticket.restore', '--ref', 'DST-999', '--author', 'claude' );
isnt( $status, 0, 'restoring a nonexistent card is refused' );
unlike( $out, qr/(?:restored|moved):/i, 'a refusal never claims a restore happened' );

# --- -o toon carries the same field, not only -o human/-o json --------------
# Codex review: the docs/Changes claim -o toon is covered too, but nothing
# actually exercised it.

my $third = $tira->create_record( project => $root, type => 'ticket', title => 'Third card' );
$tira->comment_add( project => $root, ref => $third->{ref}, author => 'claude', text => 'explained before discarding' );
( $status, $out ) = run_cli( 'ticket.discard', '--ref', $third->{ref}, '--author', 'claude', '-o', 'toon' );
is( $status, 0, 'the discard succeeds under -o toon' );
like( $out, qr/moved:.*"\Q$third->{ref}\E discarded: backlog -> discard"/s,
    '-o toon carries the same structured field discard/restore now stamp, not just -o human/-o json' );

# --- a no-op discard/restore never claims to have happened -------------------
# Codex review: neither no-op case (already resting in the destination) was
# exercised, even though the fix's own guard condition depends on it.

( $status, $out ) = run_cli( 'ticket.discard', '--ref', $third->{ref}, '--author', 'claude', '-o', 'human' );
is( $status, 0, 'discarding an already-discarded card still succeeds' );
unlike( $out, qr/(?:discarded|moved):/i,
    'but a no-op discard - already resting in discard - never claims to have discarded anything' );

$tira->record_move( project => $root, ref => $third->{ref}, column => 'backlog', author => 'claude' );
( $status, $out ) = run_cli( 'ticket.restore', '--ref', $third->{ref}, '--author', 'claude', '--column', 'backlog', '-o', 'human' );
is( $status, 0, 'restoring a card already resting in the destination column still succeeds' );
unlike( $out, qr/(?:restored|moved):/i,
    'but a no-op restore never claims to have restored anything either' );

done_testing;

__END__

=head1 NAME

1142-a-discard-that-did-not-say-so.t - a successful discard/restore
announces itself, matching TKT-785's fix for move

=head1 DESCRIPTION

TKT-1096. C<record_discard>/C<record_restore> are thin C<record_move>
wrappers, but the CLI dispatch's confirmation-stamping (TKT-785, the
C<"REF moved: FROM -> TO"> line printed ahead of the full record dump)
lived only in the C<move> branch - C<discard>/C<restore> called the engine
methods directly and returned immediately, reaching neither the stamping
nor the announcement. Both now get the same treatment: a one-line
confirmation first under C<-o human>, and a structured field alongside the
full record under C<-o json>/C<-o toon>, for both verbs. A refused call
never claims to have happened.

=cut
