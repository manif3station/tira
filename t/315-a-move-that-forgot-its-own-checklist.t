#!/usr/bin/env perl
# The browser dashboard's own move handler and the CLI/agent move path are
# supposed to be the same rule seen from two doors - the comment beside
# browser_providers' move sub says exactly that: "The browser goes through
# the same subroutines the command line goes through, so a rule cannot be
# enforced in one and forgotten in the other." True for the gating half
# (TKT-426 deliberately kept that CLI/agent-only, on purpose - a human on the
# dashboard is not an agent skipping a gate). Not true for the bookkeeping
# half: browser_providers' move sub calls $tira->record_move() directly,
# which never populates a destination column's required-action template and
# never resets one on the way back through, because that housekeeping lives
# in _apply_column_required_actions - reachable only from the CLI/agent
# dispatch path (record.move inside _invoke).
#
# Found from a live question: "when card move backward, why the required
# actions on the card not being resetted?" - a human moving a card in the
# browser, watching a required item that was already marked done stay done
# after a backward move that should have reset it. TKT-452.

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
    name => 'ReqTest', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'doc', 'code' ],
    sow_prefix => 'RQS', epic_prefix => 'RQE', ticket_prefix => 'RQT',
);
$tira->column_update( project => $root, type => 'ticket', name => 'doc', required_action => ['Write the doc'] );

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    return Tira::CLI->run( command => $command, type => 'ticket', argv => \@argv );
}

my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );

# --- the CLI/agent path populates and resets correctly (the reference behaviour) --

my $agent_card = $tira->create_record( project => $root, type => 'ticket', title => 'Moved by the CLI' );
cli( 'record.move', '--ref', $agent_card->{ref}, '--column', 'planning' );
cli( 'record.move', '--ref', $agent_card->{ref}, '--column', 'doc' );
my $items = $tira->required_item_list( project => $root, ref => $agent_card->{ref} );
is( scalar @{$items}, 1, 'CLI move into doc populates its required-action template' );
$tira->required_item_update( project => $root, ref => $agent_card->{ref}, id => $items->[0]{id}, status => 'done',
    command => ['wrote the doc'], proof => ['doc written'] );
cli( 'record.move', '--ref', $agent_card->{ref}, '--column', 'planning' );
$items = $tira->required_item_list( project => $root, ref => $agent_card->{ref} );
is( $items->[0]{status}, 'pending', 'CLI move back past doc resets its required item to pending' );

# --- the browser path must do the same, not skip it -------------------------

my $browser_card = $tira->create_record( project => $root, type => 'ticket', title => 'Moved by the browser' );
$providers{move}->( { type => 'ticket', ref => $browser_card->{ref}, column => 'planning' } );
$providers{move}->( { type => 'ticket', ref => $browser_card->{ref}, column => 'doc' } );
$items = $tira->required_item_list( project => $root, ref => $browser_card->{ref} );
is( scalar @{$items}, 1, 'a browser move into doc populates its required-action template too' );

$tira->required_item_update( project => $root, ref => $browser_card->{ref}, id => $items->[0]{id}, status => 'done',
    command => ['wrote the doc'], proof => ['doc written'] );
$providers{move}->( { type => 'ticket', ref => $browser_card->{ref}, column => 'planning' } );
$items = $tira->required_item_list( project => $root, ref => $browser_card->{ref} );
is( $items->[0]{status}, 'pending', 'and a browser move back past doc resets it to pending, same as the CLI path' );

done_testing;

__END__

=head1 NAME

315-a-move-that-forgot-its-own-checklist.t - the browser move path matches the CLI move path on required-action bookkeeping

=head1 DESCRIPTION

C<browser_providers>' C<move> handler is what the dashboard's drag-move UI
actually calls. Before TKT-452 it called C<$tira-E<gt>record_move()> directly,
so a destination column's required-action template never populated on a
browser move, and a done required item never reset on a browser move
backward - both work correctly through the CLI/agent path, which routes
through C<_apply_column_required_actions>. TKT-426's CLI/agent-only *gating*
(refusing a move with undone required actions) stays exactly as it was; this
is about the bookkeeping half, which should never have been CLI-only.

=cut
