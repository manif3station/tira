#!/usr/bin/env perl
# TKT-783. _populate_entry_required_actions's fast-path (lib/Tira/CLI.pm:1209)
# skips required_item_add entirely when a pre-existing required item's text
# and column already match a column's entry template - "do the work early"
# (TKT-652's own precedent). But required_item_add is also the only place
# that stamps entry=>1 onto a matching existing item (lib/Tira.pm:4860). So
# skipping the call altogether means a pre-existing item never picks up the
# entry marker through a real move-in - only a FRESH item, created because no
# match existed, ever gets entry=>1 at all.
#
# t/449 already proves entry=>1 protects an item from a later column-template
# rename. This is the same protection, for the case t/449 never took: the
# item existed BEFORE the entry template did.
#
# WRITTEN RED.

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
    project => $root, name => 'Early', dir => $root,
    members => ['claude'], columns => ['backlog, implement, done'],
    sow_prefix => 'EAS', epic_prefix => 'EAE', ticket_prefix => 'EAT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'x', author => 'claude' );

# --- the pre-existing item: added by hand, before any entry template names it -

$tira->required_item_add(
    project => $root, ref => $card->{ref}, item => 'assign yourself to the card',
    status => 'done', column => 'implement', author => 'claude',
    command => ['assigned via the CLI'], proof => ['claude is now the assignee'],
);

# --- THE CARD: the column declares that exact wording as an entry template ---

$tira->column_update( project => $root, type => 'ticket', name => 'implement',
    entry_required_action => ['assign yourself to the card'] );

# --- the real move-in path, not a direct required_item_add call -------------

{
    local $ENV{TIRA_HOME} = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    Tira::CLI->run(
        command => 'record.move', tira => $tira, type => 'ticket',
        argv => [ '--ref', $card->{ref}, '--column', 'implement' ],
    );
}

my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
my ($item) = grep { ( $_->{item} // '' ) eq 'assign yourself to the card' } @{ $shown->{required_items} };

ok( $item, 'the pre-existing item is still there, not duplicated' );
ok( $item->{entry}, 'and it now carries the entry marker, picked up through the real move-in path' )
  or diag('entry marker was never stamped - the fast-path skip bypassed the upgrade');

is( scalar( grep { ( $_->{item} // '' ) eq 'assign yourself to the card' } @{ $shown->{required_items} } ), 1,
    'and only one copy exists - no duplicate was created by taking the slow path' );

# --- the marker still protects against a later rename, same as t/449 --------

$tira->column_update( project => $root, type => 'ticket', name => 'implement',
    entry_required_action => ['renamed wording'] );

my $card2 = $tira->create_record( project => $root, type => 'ticket', title => 'y', author => 'claude' );
{
    local $ENV{TIRA_HOME} = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    Tira::CLI->run( command => 'record.move', tira => $tira, type => 'ticket',
        argv => [ '--ref', $card2->{ref}, '--column', 'implement' ] );
}

my $reshown = $tira->record_show( project => $root, ref => $card->{ref} );
my ($still) = grep { ( $_->{item} // '' ) eq 'assign yourself to the card' } @{ $reshown->{required_items} };
ok( $still && $still->{entry}, 'the earlier card, now carrying the marker, is unaffected by the rename' );

done_testing();

__END__

=head1 NAME

t/783-an-item-that-was-already-there.t - a pre-existing required item picks
up the entry marker through a real move-in

=head1 DESCRIPTION

TKT-783. C<_populate_entry_required_actions>'s fast-path skipped
C<required_item_add> entirely when a pre-existing item's text and column
already matched a column's entry template - so the C<entry =E<gt> 1> upgrade
inside C<required_item_add>, the only place that stamps it onto a matching
existing item, was never reached. Only a genuinely fresh item, created
because no match existed, ever carried the marker.

Fixed by always calling C<required_item_add> - its own idempotent dedup
(TKT-497) already handles "the item is already there" without creating a
duplicate, and its existing-item branch (TKT-652) is what stamps the marker.

=cut
