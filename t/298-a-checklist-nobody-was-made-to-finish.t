#!/usr/bin/env perl
# A column's checklist item was always just a suggestion: nothing tied it to
# entering or leaving a specific column, and nothing stopped a card leaving
# with it still unmarked. The owner asked for each column to carry its own
# required-action template (TG msg 4126-4145): moving a card in adds that
# column's items to its checklist without duplicating on re-entry, and moving
# it out refuses while any of them are still unmarked. A backward move stays
# an escape hatch regardless - the unmet item may be exactly what a card is
# retreating to fix - but resets to undone every required item belonging to a
# column strictly between the new position (exclusive) and the old one
# (inclusive), since redoing that work means satisfying the check again on
# the way back through (EPC-002 comment, 17:11:14). TKT-427.

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
    name => 'Required', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'doc', 'code', 'test', 'done' ],
    sow_prefix => 'REQ', epic_prefix => 'REE', ticket_prefix => 'RET',
);

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    local $ENV{TIRA_AUTHOR} = "claude";
    my $status = Tira::CLI->run( command => $command, type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

sub move {
    my ( $ref, $column ) = @_;
    return cli( 'record.move', '--ref', $ref, '--column', $column );
}

sub checklist_of {
    my ($ref) = @_;
    return $tira->record_show( project => $root, ref => $ref )->{required_items};
}

sub item_status {
    my ( $ref, $text ) = @_;
    my ($item) = grep { $_->{item} eq $text } @{ checklist_of($ref) };
    return $item ? $item->{status} : undef;
}

# --- configuring a column's required actions, and the guard around it -----
my ( $status, $out, $err ) = cli(
    'column.update',
    '--type', 'ticket', '--name', 'planning', '--required-action', 'left a note',
);
is( $status, 0, 'setting a required action on a column succeeds' );
cli( 'column.update', '--type', 'ticket', '--name', 'doc', '--required-action', 'reviewed' );
cli( 'column.update', '--type', 'ticket', '--name', 'code', '--required-action', 'tests green' );

my %column = map { $_->{name} => $_ } @{ $tira->column_list( project => $root, type => 'ticket' ) };
is_deeply( $column{planning}{required_actions}, ['left a note'], 'the template persists on the column' );
is_deeply( $column{done}{required_actions}, [], 'an unconfigured column carries no template' );

( $status, $out, $err ) = cli(
    'record.move', '--ref', 'RET-1', '--column', 'planning', '--required-action', 'nope',
);
isnt( $status, 0, 'required-action is refused on a command other than column.update' );
like( $err, qr/column\.update/, 'and says which command it belongs to' );

# --- the card itself, walked forward -----------------------------------
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Walks the chain' );
my $ref  = $card->{ref};

( $status, $out, $err ) = move( $ref, 'planning' );
is( $status, 0, 'the immediate next column is reachable' ) or diag($err);
is( scalar @{ checklist_of($ref) }, 1, 'entering a column with a template adds one item' );
is( checklist_of($ref)->[0]{item}, 'left a note', 'named after the column template' );
is( item_status( $ref, 'left a note' ), 'pending', 'and starts unmarked' );

( $status, $out, $err ) = move( $ref, 'doc' );
isnt( $status, 0, 'leaving planning with its item unmarked refuses' );
like( $err, qr/left a note/, 'and names the unmet item' );
like( $err, qr/\Q$ref\E/, 'and names the card' );
is( $tira->record_show( project => $root, ref => $ref )->{column}, 'planning', 'the card did not move' );

my ($note) = grep { $_->{item} eq 'left a note' } @{ checklist_of($ref) };
$tira->required_item_update( project => $root, ref => $ref, id => $note->{id}, status => 'done',
    command => ['left it'], proof => ['note left'] );
( $status, $out, $err ) = move( $ref, 'doc' );
is( $status, 0, 'moving out succeeds once the required item is marked done' ) or diag($err);
is( $tira->record_show( project => $root, ref => $ref )->{column}, 'doc', 'and the card actually moved' );
is( scalar @{ checklist_of($ref) }, 2, "entering doc adds its own item on top of planning's" );
is( item_status( $ref, 'reviewed' ), 'pending', "doc's template item is present and unmarked" );

my ($reviewed) = grep { $_->{item} eq 'reviewed' } @{ checklist_of($ref) };
$tira->required_item_update( project => $root, ref => $ref, id => $reviewed->{id}, status => 'done',
    command => ['reviewed it'], proof => ['review complete'] );
( $status, $out, $err ) = move( $ref, 'code' );
is( $status, 0, "moving into code succeeds once doc's item is done too" ) or diag($err);
is( scalar @{ checklist_of($ref) }, 3, "code's own item is added" );
is( item_status( $ref, 'tests green' ), 'pending', "code's item starts unmarked, as if tests had not run yet" );

# --- backward, skipping doc entirely: the escape hatch stays open even
#     though 'tests green' is still unmet -----------------------------
( $status, $out, $err ) = move( $ref, 'planning' );
is( $status, 0, "a backward move succeeds regardless of code's unmarked item" ) or diag($err);
is( $tira->record_show( project => $root, ref => $ref )->{column}, 'planning', 'landed back at planning' );
is( scalar @{ checklist_of($ref) }, 3, 're-entering planning adds nothing new - no duplicate items' );
is( item_status( $ref, 'left a note' ), 'pending',
    "planning's own item resets too - it is the destination the card actually landed on" );
is( item_status( $ref, 'reviewed' ), 'pending',
    "doc's item resets to undone - it sits between the destination and the old position" );
is( item_status( $ref, 'tests green' ), 'pending',
    "code's item was already unmet and stays unmet after the reset" );

# --- proving the reset is real: leaving planning now refuses again too,
#     the same as doc -----------------------------------------------------
( $status, $out, $err ) = move( $ref, 'doc' );
isnt( $status, 0, "planning's own reset held: leaving it needs its item marked done again" );
like( $err, qr/left a note/, 'naming the item the reset put back on the destination itself' );

$tira->required_item_update( project => $root, ref => $ref,
    id => ( grep { $_->{item} eq 'left a note' } @{ checklist_of($ref) } )[0]{id},
    status => 'done', command => ['left it again'], proof => ['note left'] );
( $status, $out, $err ) = move( $ref, 'doc' );
is( $status, 0, "and leaving succeeds again once planning's item is redone" ) or diag($err);
( $status, $out, $err ) = move( $ref, 'code' );
isnt( $status, 0, "doc's reset held too: its item is unmarked again and blocks leaving" );
like( $err, qr/reviewed/, 'naming the item the reset put back' );

done_testing;

__END__

=head1 NAME

298-a-checklist-nobody-was-made-to-finish.t - Column-scoped required actions on move

=head1 DESCRIPTION

Covers TKT-427: a column's required-action template is added to a card's
checklist on entry, without duplicating on re-entry; a forward departure
refuses while any of the current column's required items are unmarked; a
backward move stays unconditional but resets every required item belonging
to a column strictly between the new position and the old one.

=cut
