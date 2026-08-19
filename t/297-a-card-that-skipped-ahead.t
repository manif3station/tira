#!/usr/bin/env perl
# A card could be moved to any column regardless of position - backlog
# straight to done, skipping every step the board's own column order implies.
# column-skipped (POL-041) already reports this after the fact, asynchronously,
# and moves nothing: the card lands wherever it was sent and the violation is
# discovered later, if at all. The owner asked for the move command itself to
# refuse the jump, synchronously, naming the correct next column - and for the
# refusal to apply only to the CLI/agent path, not the browser dashboard.
# TKT-426.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );

my $tira = Tira->new;
$tira->project_new(
    name => 'Chain', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'doc', 'code', 'done' ],
    sow_prefix => 'CHS', epic_prefix => 'CHE', ticket_prefix => 'CHT',
);

sub cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => 'record.move', type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Follows the chain' );

# --- the owner's own example: backlog straight to code, skipping planning and doc
my ( $status, $out, $err ) = cli( '--ref', $card->{ref}, '--column', 'code' );
isnt( $status, 0, 'a forward skip refuses' );
like( $err, qr/planning/, 'and names the correct next column' );
like( $err, qr/\Q$card->{ref}\E/, 'and names the card' );
is( $tira->record_show( project => $root, ref => $card->{ref} )->{column}, 'backlog',
    'the card did not move' );

# --- the immediate next column succeeds
( $status, $out, $err ) = cli( '--ref', $card->{ref}, '--column', 'planning' );
is( $status, 0, 'moving to the immediate next column succeeds' );
is( $tira->record_show( project => $root, ref => $card->{ref} )->{column}, 'planning',
    'and the card actually moved' );

# --- another forward skip from the new position
( $status, $out, $err ) = cli( '--ref', $card->{ref}, '--column', 'done' );
isnt( $status, 0, 'skipping ahead from the new position still refuses' );
like( $err, qr/doc/, 'naming doc as the correct next column from here' );

# --- walk it forward properly, then a backward move to redo work
cli( '--ref', $card->{ref}, '--column', 'doc' );
cli( '--ref', $card->{ref}, '--column', 'code' );
( $status, $out, $err ) = cli( '--ref', $card->{ref}, '--column', 'planning' );
is( $status, 0, 'a backward move (redoing work) succeeds - only forward skips refuse' );

# --- discard is exempt regardless of position
( $status, $out, $err ) = cli( '--ref', $card->{ref}, '--column', 'discard' );
is( $status, 0, 'moving to discard succeeds from any column, skip or not' );

# --- the browser dashboard's own path is unrestricted: a direct engine call
# (bypassing Tira::CLI entirely, the way browser_providers' move coderef does)
# is not subject to the chain check at all.
my $unrestricted = $tira->create_record( project => $root, type => 'ticket', title => 'Dashboard-moved' );
my $direct = eval {
    $tira->record_move( project => $root, ref => $unrestricted->{ref}, column => 'done' );
    1;
};
ok( $direct, 'a direct record_move call - the dashboard\'s own path - is not restricted by the chain' );
is( $tira->record_show( project => $root, ref => $unrestricted->{ref} )->{column}, 'done',
    'and the card actually reached the skipped-ahead column' );

done_testing;

__END__

=head1 NAME

297-a-card-that-skipped-ahead.t - the move command refuses a forward skip in
the column chain

=head1 DESCRIPTION

A move that skips ahead past the immediate next column in the board's
declared order refuses, naming the correct next column and the card. Backward
moves stay free - redoing work after a step back is not the fake-move
problem this closes. discard is always exempt. The check lives in the CLI
dispatch layer, so a direct engine call - the path the browser dashboard's
own move provider uses - is unrestricted, per the owner's explicit scope.

=cut
