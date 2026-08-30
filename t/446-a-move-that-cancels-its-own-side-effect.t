#!/usr/bin/env perl
# TKT-632. _reset_linked_tasks_on_return (lib/Tira/CLI.pm) calls
# tasklist_list( %{$args}, all_sessions => 1 ) - the move command's ENTIRE
# argument set, not just what tasklist_list is meant to receive. Getopt
# parses --status through one shared @spec, so a move carrying --status
# (an option move itself does nothing with) hands that value straight to
# tasklist_list, which honours --status as a filter and DIES on a value it
# does not recognise. The die is swallowed by "return if ref $items ne
# 'ARRAY'" one line later, so a working task's status is silently never
# reset when a card goes back to backlog - the exact side effect this
# function exists to guarantee.
#
# Reproduced against the pre-fix source (lib/Tira/CLI.pm:1625-1657): a
# control move with no --status resets the task; the same move with
# --status carrying a value tasklist_list rejects (or even one it accepts,
# like 'done', which is simply the wrong filter) does not, and says
# nothing about why.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-30T05:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Splat', dir => $root, members => ['claude'],
    columns    => [ 'backlog', 'implement', 'done' ],
    sow_prefix => 'SPS', epic_prefix => 'SPE', ticket_prefix => 'SPT',
);

sub run {
    my ( $command, @argv ) = @_;
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME}   = $root;
            local $ENV{TIRA_AUTHOR} = 'claude';
            Tira::CLI->run( command => $command, type => $type, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# --- control: a plain move back to backlog resets a working task ------------

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Control card' );
$tira->record_move( project => $root, ref => $card->{ref}, type => 'ticket', column => 'implement', author => 'claude' );
my $task = $tira->tasklist_add( project => $root, text => 'Working the control card', session => 'claude' );
$tira->tasklist_task_ref_link( project => $root, id => $task->{id}, refs => [ $card->{ref} ], session => 'claude' );
$tira->tasklist_update( project => $root, id => $task->{id}, status => 'working', session => 'claude' );

run( 'ticket.move', '--ref', $card->{ref}, '--column', 'backlog' );
my ($control) = grep { $_->{id} eq $task->{id} }
  @{ $tira->tasklist_list( project => $root, all_sessions => 1 ) };
is( $control->{status}, 0, 'control: a move back to backlog with no --status resets the linked task to pending' );

# --- the bug: the same move, but carrying an unrelated --status -------------

my $card2 = $tira->create_record( project => $root, type => 'ticket', title => 'Card moved with --status' );
$tira->record_move( project => $root, ref => $card2->{ref}, type => 'ticket', column => 'implement', author => 'claude' );
my $task2 = $tira->tasklist_add( project => $root, text => 'Working the second card', session => 'claude' );
$tira->tasklist_task_ref_link( project => $root, id => $task2->{id}, refs => [ $card2->{ref} ], session => 'claude' );
$tira->tasklist_update( project => $root, id => $task2->{id}, status => 'working', session => 'claude' );

run( 'ticket.move', '--ref', $card2->{ref}, '--column', 'backlog', '--status', 'done' );
my ($after) = grep { $_->{id} eq $task2->{id} }
  @{ $tira->tasklist_list( project => $root, all_sessions => 1 ) };
is( $after->{status}, 0,
    'a move carrying an unrelated --status still resets the linked task to pending - '
      . "if this is 1 (working), the --status splat into tasklist_list silently cancelled the reset" );

done_testing();

__END__

=head1 NAME

t/446-a-move-that-cancels-its-own-side-effect.t - an unrelated --status on
a move must not cancel the linked-task reset

=head1 DESCRIPTION

C<_reset_linked_tasks_on_return> in C<lib/Tira/CLI.pm> passed the move
command's entire argument hash into C<tasklist_list>, including a
C<--status> value the move command itself does nothing with.
C<tasklist_list> treats C<status> as a filter and dies on an unrecognised
value; that die was swallowed by C<return if ref $items ne 'ARRAY'>, so
the task reset silently never ran. TKT-632.

=cut
