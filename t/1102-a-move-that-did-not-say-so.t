#!/usr/bin/env perl

# TKT-785. record.move's dispatch (lib/Tira/CLI.pm) returns the whole
# re-fetched record on success - the same full dump tira.TYPE.show gives,
# with every field (comments, required_items, checklist, gate_passing_log,
# evidence...). For a card with real history this runs to 100+ lines, and
# the one fact that actually confirms the move worked - the new column - is
# buried somewhere in the middle rather than announced up front.
#
# MEASURED CONSEQUENCE: TKT-775 sat stalled in verify for roughly two hours
# because its own move-to-pending-push call was never actually confirmed to
# have landed, caught only when an unrelated 30-minute police poll flagged
# it independently.
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

my $tira = Tira->new( clock => sub { '2026-09-15T09:00:00Z' } );
$tira->project_new(
    name => 'MoveSaysSo', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'MSS', epic_prefix => 'MSE', ticket_prefix => 'MST',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'A card with history' );
$tira->comment_add( project => $root, ref => $card->{ref}, author => 'claude', text => 'a comment, so the full dump is not tiny' );

# --- -o human: a one-line confirmation, at the START, before the full dump -

my ( $status, $out ) = run_cli( 'ticket.move', '--ref', $card->{ref}, '--column', 'implement', '--author', 'claude', '-o', 'human' );
is( $status, 0, 'the move succeeds' );

my ($first_line) = split /\n/, $out, 2;
like( $first_line, qr/\Q$card->{ref}\E\s+moved:\s*backlog\s*->\s*implement/i,
    'the FIRST line of -o human move output names the ref, the source '
      . 'column and the destination column - not buried in a full dump' );

like( $out, qr/\Q$card->{ref}\E/,
    'the full record still follows - nothing that reads the whole output '
      . 'loses information' );

cmp_ok( length($out), '>', length($first_line) + 20,
    'the full record is genuinely still there, not replaced by the summary '
      . 'line alone' );

# --- -o json / -o toon: a structured field alongside the full record, ------
# not instead of it --------------------------------------------------------

my $second = $tira->create_record( project => $root, type => 'ticket', title => 'Second card' );

( $status, $out ) = run_cli( 'ticket.move', '--ref', $second->{ref}, '--column', 'implement', '-o', 'json', '--author', 'claude' );
is( $status, 0, 'the move succeeds under -o json' );
my $decoded = decode_json($out);
is( $decoded->{moved}, "$second->{ref} moved: backlog -> implement",
    '-o json carries a structured "moved" field naming both columns' );
is( $decoded->{ref}, $second->{ref},
    'and the full record - starting with its own ref - is still there too, '
      . 'not replaced by the summary field' );
is( $decoded->{column}, 'implement',
    'including the real, current column' );

( $status, $out ) = run_cli( 'ticket.move', '--ref', $second->{ref}, '--column', 'done', '-o', 'toon', '--author', 'claude' );
is( $status, 0, 'the move succeeds under -o toon' );
like( $out, qr/moved:.*"\Q$second->{ref}\E moved: implement -> done"/s,
    '-o toon carries the same structured field' );
like( $out, qr/\Q$second->{ref}\E/,
    'and the full record is still there in toon too' );

# --- a refused move is unaffected: it already says what and why ------------

( $status, $out, my $err ) = run_cli( 'ticket.move', '--ref', $card->{ref}, '--column', 'nowhere-such-column', '--author', 'claude' );
isnt( $status, 0, 'a move to a column that does not exist is refused' );
unlike( $out, qr/moved:/i, 'a refusal never claims a move happened' );

# --- "from" is the column THIS move actually left, not a stale read --------
#
# Codex review found the first version read the "from" column with its own
# separate record_show call, taken BEFORE record_move's own lock - a real
# race with a concurrent writer, reproduced directly. record_move now
# reports previous_column from inside the very lock that performs the
# rename, so there is no separate read left to race. Proved here without
# needing real concurrency: move the card once more first (backlog is
# already left behind by the earlier moves above), then move it again and
# confirm "from" names its ACTUAL immediately-prior column, not some
# earlier one a stale read could have returned.

$tira->comment_add( project => $root, ref => $card->{ref}, author => 'claude', text => 'setting up the from-column check' );
( $status, $out ) = run_cli( 'ticket.move', '--ref', $card->{ref}, '--column', 'done', '--author', 'claude', '-o', 'human' );
is( $status, 0, 'moving the card again succeeds' );
( $first_line ) = split /\n/, $out, 2;
like( $first_line, qr/\Q$card->{ref}\E\s+moved:\s*implement\s*->\s*done/i,
    '"from" names the column this move actually left (implement, where the '
      . 'earlier -o human move put it), not any earlier column' );

# --- a no-op move (already resting in the destination column) never claims -
# to have moved anything - Codex review found the first version reported
# "REF moved: X -> X" for this case, since it checked only whether $from was
# defined, not whether it differed from the destination. -------------------

( $status, $out ) = run_cli( 'ticket.move', '--ref', $card->{ref}, '--column', 'done', '--author', 'claude', '-o', 'human' );
is( $status, 0, 'moving a card onto the column it is already resting in still succeeds' );
unlike( $out, qr/moved:/i,
    'but it never claims a move happened, since nothing about the record '
      . 'actually changed' );

done_testing;

__END__

=head1 NAME

1102-a-move-that-did-not-say-so.t - a successful move announces itself

=head1 WHY

TKT-785. record.move's output was the same full record dump
tira.TYPE.show gives, with the one fact that confirms a move worked -
the new column - buried in the middle. A real card (TKT-775) sat stalled
for two hours because of exactly this.

=head1 WHAT IS ASSERTED

A successful move's -o human output starts with a "REF moved: FROM ->
TO" line, followed by the unabridged full record. -o json/-o toon carry
an equivalent structured "moved" field alongside every other field,
never replacing them. A refused move never claims to have moved
anything, and neither does a no-op move onto the column a card already
rests in.

=head1 WHAT IS NOT ASSERTED

Anything about how the browser's own move provider (record_move called
directly, not through this CLI dispatch layer) presents a move - out of
scope, per TKT-426's own precedent that the CLI/agent path and the
browser path are deliberately different code.

=cut
