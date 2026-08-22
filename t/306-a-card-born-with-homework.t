#!/usr/bin/env perl
# TKT-427's move-in population never fires for the very first column a card
# lands in, because creation is not a move. A card created directly into the
# board's entry column (TKT-428) - or any column carrying required_actions -
# had none of that column's required items until it moved away and back,
# which it may never legitimately need to do. Owner, TG voice msg 4188:
# "created的陣...已經set了每一個column就有這些required item...那張card一created的陣,那些
# required item就會自動加進去的card" - the entry column's required items
# should already be on the card the moment it is created. TKT-439.

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
    name => 'Born', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'doc' ],
    sow_prefix => 'BNS', epic_prefix => 'BNE', ticket_prefix => 'BNT',
);
$tira->column_update( project => $root, type => 'ticket', name => 'planning', required_action => [ 'left a note', 'said why' ] );

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    $ENV{TIRA_AUTHOR} = 'claude';
    my $status = Tira::CLI->run( command => $command, type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

# --- created into a column with no required_actions: nothing added --------
my ( $status, $out, $err ) = cli( 'record.create', '--title', 'Backlog card' );
is( $status, 0, 'creating with no --column succeeds' ) or diag($err);
my $backlog_card = $tira->record_list( project => $root, type => 'ticket' )->[0];
is( scalar @{ $backlog_card->{required_items} }, 0, 'backlog carries no required_actions - nothing added' );

# --- created directly into a column WITH required_actions configured ------
( $status, $out, $err ) = cli( 'record.create', '--title', 'Born in planning', '--column', 'planning' );
is( $status, 0, 'creating directly into planning succeeds' ) or diag($err);
my ($planning_card) = grep { $_->{title} eq 'Born in planning' } @{ $tira->record_list( project => $root, type => 'ticket' ) };
is( scalar @{ $planning_card->{required_items} }, 2, 'both of planning\'s required items are already on the card' );
ok( ( grep { $_->{item} eq 'left a note' && $_->{status} eq 'pending' } @{ $planning_card->{required_items} } ),
    'the first item, unmarked' );
ok( ( grep { $_->{item} eq 'said why' && $_->{status} eq 'pending' } @{ $planning_card->{required_items} } ),
    'and the second' );

# --- and it counts as a required-action write in the work log, same as a move
my $history = $tira->history_list( project => $root, ref => $planning_card->{ref}, where => ['op=required-action'] );
is( scalar @{$history}, 2, 'both creation-time additions are tagged required-action in the work log, same as a move-in would be' );

# --- move-out still refuses while they are unticked, exactly as before -----
( $status, $out, $err ) = cli( 'record.move', '--ref', $planning_card->{ref}, '--column', 'doc' );
isnt( $status, 0, 'move-out still refuses while the creation-time items are unmarked' );
like( $err, qr/left a note/, 'naming an unmet item' );

# --- the direct engine call - the dashboard's own path - stays untouched ---
my $direct = $tira->create_record( project => $root, type => 'ticket', title => 'Dashboard bypass', column => 'planning' );
is( scalar @{ $tira->record_show( project => $root, ref => $direct->{ref} )->{required_items} }, 0,
    'a direct create_record call gets no required-action population at all' );

done_testing;

__END__

=head1 NAME

306-a-card-born-with-homework.t - creation populates required actions the same way a move-in would

=head1 DESCRIPTION

Covers TKT-439's first half: a card created directly into a column
carrying required_actions has those items on its checklist immediately,
tagged the same way TKT-427's move-in population and TKT-438's work-log
distinction already tag an automatic write. A direct create_record call
(the dashboard's own path) is unaffected.

=cut
