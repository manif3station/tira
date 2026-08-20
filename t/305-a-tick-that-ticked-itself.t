#!/usr/bin/env perl
# TKT-427's move-in population and backward-move reset write checklist
# entries the same way a person typing tira.checklist.add/update by hand
# does - one journal entry per write, correctly timestamped separately, but
# with nothing in the entry saying which kind of write it was. The owner
# asked (TG voice msg 4188) for these to be distinguishable in the work log
# from a manual tick, so a reader can tell which checklist changes the move
# mechanism made automatically and which a person or agent made by hand.
# TKT-438.

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
    name => 'Tagged', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'doc' ],
    sow_prefix => 'TGS', epic_prefix => 'TGE', ticket_prefix => 'TGT',
);
$tira->column_update( project => $root, type => 'ticket', name => 'planning', required_action => ['left a note'] );

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => $command, type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Watched' );

# --- a manual add carries no required-action tag ---------------------------
$tira->checklist_add( project => $root, ref => $card->{ref}, item => 'a manual step', status => 'pending' );
my $history = $tira->history_list( project => $root, ref => $card->{ref}, where => ['op=required-action'] );
is( scalar @{$history}, 0, 'a plain manual checklist_add writes no required-action entry' );

# --- move-in populates the checklist, tagged distinctly from a manual add --
cli( 'record.move', '--ref', $card->{ref}, '--column', 'planning' );
$history = $tira->history_list( project => $root, ref => $card->{ref}, where => ['op=required-action'] );
is( scalar @{$history}, 1, 'move-in population writes one required-action-tagged entry' );
is( $history->[0]{item}, 'left a note', 'naming the item it added' );
is( $history->[0]{after}, 'pending', 'and the status it started at' );

# --- mark it done manually - still no tag, this was a person's own tick ----
my ($entry) = grep { $_->{item} eq 'left a note' } @{ $tira->checklist_list( project => $root, ref => $card->{ref} ) };
$tira->checklist_update( project => $root, ref => $card->{ref}, id => $entry->{id}, status => 'done' );
$history = $tira->history_list( project => $root, ref => $card->{ref}, where => ['op=required-action'] );
is( scalar @{$history}, 1, 'a manual checklist_update adds no new required-action entry' );

# --- backward move resets it, tagged again, distinctly from the manual tick
cli( 'record.move', '--ref', $card->{ref}, '--column', 'backlog' );
$history = $tira->history_list( project => $root, ref => $card->{ref}, where => ['op=required-action'] );
is( scalar @{$history}, 2, 'the backward-move reset writes its own second required-action entry' );
is( $history->[1]{item}, 'left a note', 'naming the item it reset' );
is( $history->[1]{after}, 'pending', 'and that it went back to pending' );

done_testing;

__END__

=head1 NAME

305-a-tick-that-ticked-itself.t - required-action checklist writes are tagged in the work log

=head1 DESCRIPTION

Covers TKT-438's work-log ask: checklist_add and checklist_update accept an
optional source => 'required-action', which writes an extra, distinctly
tagged history entry (op => 'required-action', field => 'checklist') on
top of the generic per-write entry every checklist change already gets. A
plain manual call carries no such tag.

=cut
