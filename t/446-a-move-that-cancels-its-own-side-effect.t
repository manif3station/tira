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

# --- the bug: the same move, but carrying an unrelated option ---------------
#
# THE PROBE USED TO BE --status AND CANNOT BE ANY MORE, which is worth writing
# down rather than quietly swapping. Since 5.43 a move carrying --status is
# REFUSED by name - record.move does not read it, and %OPTION_READ_BY now says
# so (TKT-748). The move never runs, so it can no longer reach the function this
# file is about, and asserting the reset through it would be asserting that a
# refused command has a side effect.
#
# The fault itself is unchanged and still reachable. --sort is the same shape:
# an option the shared Getopt spec parses on every command, that a move does
# nothing with, and that tasklist_list DOES act on - and since 5.42 it dies on a
# spec it cannot honour (TKT-888), which is exactly the "value tasklist_list
# rejects" this file's header describes. TKT-581 is the open card for --sort
# being unguarded; while it is, it is the honest probe for this.
#
# So the guarantee under test is the same one: _reset_linked_tasks_on_return
# must ask the tasklist for project and all_sessions ONLY, whatever else the
# move was carrying.

my $card2 = $tira->create_record( project => $root, type => 'ticket', title => 'Card moved with an unrelated option' );
$tira->record_move( project => $root, ref => $card2->{ref}, type => 'ticket', column => 'implement', author => 'claude' );
my $task2 = $tira->tasklist_add( project => $root, text => 'Working the second card', session => 'claude' );
$tira->tasklist_task_ref_link( project => $root, id => $task2->{id}, refs => [ $card2->{ref} ], session => 'claude' );
$tira->tasklist_update( project => $root, id => $task2->{id}, status => 'working', session => 'claude' );

run( 'ticket.move', '--ref', $card2->{ref}, '--column', 'backlog', '--sort', 'bogus:desc' );
my ($after) = grep { $_->{id} eq $task2->{id} }
  @{ $tira->tasklist_list( project => $root, all_sessions => 1 ) };
is( $after->{status}, 0,
    'a move carrying an unrelated --sort still resets the linked task to pending - '
      . 'if this is 1 (working), the option splatted into tasklist_list, which '
      . 'refuses that spec, and the die cancelled the reset' );

# --- and the option that used to be the probe is now refused outright --------
#
# The stronger outcome of the two, and the reason the probe had to move. An
# option a command cannot act on is refused by name rather than accepted and
# dropped, so this route to the fault is closed at the door instead of being
# survived further in.

my $card4 = $tira->create_record( project => $root, type => 'ticket', title => 'Card moved with --status' );
$tira->record_move( project => $root, ref => $card4->{ref}, type => 'ticket', column => 'implement', author => 'claude' );
my $task4 = $tira->tasklist_add( project => $root, text => 'Working the fourth card', session => 'claude' );
$tira->tasklist_task_ref_link( project => $root, id => $task4->{id}, refs => [ $card4->{ref} ], session => 'claude' );
$tira->tasklist_update( project => $root, id => $task4->{id}, status => 'working', session => 'claude' );

my ( undef, $said4 ) = run( 'ticket.move', '--ref', $card4->{ref}, '--column', 'backlog', '--status', 'done' );
like( $said4, qr/does not act on --status/,
    'a move carrying --status is refused by name - record.move never read it, '
      . 'and an option accepted and dropped is the fault this whole family is '
      . 'about (TKT-748)' );

my ($unmoved) = grep { $_->{id} eq $task4->{id} }
  @{ $tira->tasklist_list( project => $root, all_sessions => 1 ) };
is( $unmoved->{status}, 1,
    'and the refusal is a refusal: the card did not move, so its task is still '
      . 'working rather than reset - a refused command with half its side '
      . 'effects done would be worse than either outcome' );

# --- a genuine tasklist_list failure is reported, not swallowed -------------

my $card3 = $tira->create_record( project => $root, type => 'ticket', title => 'Corrupted tasklist' );
$tira->record_move( project => $root, ref => $card3->{ref}, type => 'ticket', column => 'implement', author => 'claude' );

my $tasklist_path = File::Spec->catfile( $root, '.tira', 'tasklist.json' );
open my $fh, '>', $tasklist_path or die $!;
print {$fh} 'not valid json';
close $fh;

my ( undef, $said3 ) = run( 'ticket.move', '--ref', $card3->{ref}, '--column', 'backlog' );
like( $said3, qr/Could not check for linked tasks to reset/,
    'a genuine tasklist_list failure (corrupt storage, not a bad --status) is reported to the caller, not silently swallowed' );

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

=head1 WHY THE PROBE IS NOT --status ANY MORE

Since 5.43 a move carrying C<--status> is refused by name: C<record.move>
does not read it, and C<%OPTION_READ_BY> says so (TKT-748). The move never
runs, so it cannot reach the function this file guards, and asserting a
side effect of a refused command would assert nothing.

The fault is unchanged. C<--sort> is the same shape - parsed by the shared
Getopt spec on every command, done nothing with by a move, and acted on by
C<tasklist_list>, which since 5.42 dies on a spec it cannot honour
(TKT-888). That is the "value tasklist_list rejects" the header describes,
still reachable. TKT-581 is the open card for C<--sort> being unguarded;
if it is closed, this probe needs the same treatment as C<--status> did.

The refusal itself is asserted here too, along with the fact that a refused
move leaves its task alone - a command that refuses and still performs half
its side effects would be worse than either outcome.

=cut
