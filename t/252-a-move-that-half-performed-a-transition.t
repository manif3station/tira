#!/usr/bin/env perl
# A move given a gate to set does not pretend to have set it.
#
# Reported by Zenandi and reproduced here rather than taken on trust: a card at
# gate G2, moved with --sdlc-gate G9, comes back in the new column, still at
# G2, exit 0, with the whole card printed - which reads as confirmation because
# the card is right there.
#
# The same shape as --field, fixed this morning: an option a command does not
# act on, accepted and dropped. It costs more here than it did there. Their
# board's rules require the gate to be updated with every transition, so "move
# and set the gate" is the most natural thing to type on it - the correct
# action, expressed in one command, silently half-done.
#
# Refused rather than made to work, and that is a decision with two defensible
# answers. The other is to let move carry the gate, one command doing the whole
# transition, which is what they asked for. The refusal wins here because it is
# the mechanism already shipped for --field, it cannot do the wrong thing
# quietly, and it is reversible: teaching move to act on the flag later is an
# addition, while un-teaching callers that it works is not.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-17T07:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Transitions', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'TRS', epic_prefix => 'TRE', ticket_prefix => 'TRT',
);

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Moving, with a gate to set', sdlc_gate => 'G2' );

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
            local $ENV{TIRA_HOME} = $root;
            local $ENV{TIRA_AUTHOR} = 'claude';
            Tira::CLI->run( command => $command, type => $type, tira => $tira,
                argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

sub gate_of {
    return $tira->record_show( project => $root, ref => $card->{ref} )->{sdlc_gate};
}

# --- the card starts where it says it does ------------------------------------

is( gate_of(), 'G2', 'the card is at the gate it was created with' );

# --- a move told to set a gate ------------------------------------------------

{
    my ( $status, $said ) = run( 'ticket.move', '--ref', $card->{ref},
        '--column', 'implement', '--sdlc-gate', 'G9' );

    isnt( $status, 0, 'a move given a gate to set is refused' );
    like( $said, qr/--sdlc-gate/, 'naming the option it will not act on' );
    like( $said, qr/update/, 'and the command that does act on it' );

    is( gate_of(), 'G2',
        'and the gate is untouched, which it was before as well - the difference is being told' );
    is( $tira->record_show( project => $root, ref => $card->{ref} )->{column},
        'backlog', 'and the card has not moved either, so nothing is half-done' );
}

# --- while the commands that do act on it are untouched ------------------------

{
    my ($moved) = run( 'ticket.move', '--ref', $card->{ref}, '--column', 'implement' );
    is( $moved, 0, 'a move with no gate to set works as it always did' );

    my ($updated) = run( 'ticket.update', '--ref', $card->{ref}, '--sdlc-gate', 'G9' );
    is( $updated, 0, 'and the command that sets a gate still sets one' );
    is( gate_of(), 'G9', 'so the transition is done in two commands that each do what they say' );

    my $fresh = $tira->create_record( project => $root, type => 'ticket',
        title => 'Created at a gate', sdlc_gate => 'G1' );
    is( $fresh->{sdlc_gate}, 'G1', 'and a card can still be created at a gate' );
}

# --- proved by accepting the option again --------------------------------------
#
# With the refusal removed, the move succeeds and the gate stays behind, which
# is the state that was reported.

{
    no warnings 'redefine';
    local *Tira::CLI::_refuse_unread_options = sub { return };

    $tira->record_update( author => 'claude', project => $root, ref => $card->{ref}, sdlc_gate => 'G2' );
    my ($status) = run( 'ticket.move', '--ref', $card->{ref},
        '--column', 'done', '--sdlc-gate', 'G9' );

    is( $status, 0, 'without the refusal the move reports success' );
    is( gate_of(), 'G2', 'while the gate it was told to set stayed behind' );
}

done_testing;

__END__

=head1 NAME

252-a-move-that-half-performed-a-transition.t - the gate a move would not set

=head1 DESCRIPTION

C<tira.ticket.move> accepted C<--sdlc-gate>, ignored it, and exited 0 after
printing the card. On a board whose rules require the gate to move with every
transition, that is the correct action expressed in one command and silently
half-done.

It is refused now, naming the command that does set a gate. The alternative -
letting move carry the gate - is recorded on the card as a decision rather than
an oversight.

=cut
