#!/usr/bin/env perl
# TKT-643. A resting/ending column (done, install, push) attaches
# required_items on entry the same as any working column, but no police
# rule ever sweeps for items still unmet in the card's own CURRENT column -
# the departure gate (_column_required_action_violation) only fires on the
# way OUT of a column, and required-action-stranded (TKT-612) deliberately
# excludes ending columns and only looks BEHIND the current column, never
# AT it. So a card can rest in done forever with an unsatisfied required
# item for done itself and nothing will ever report it. Confirmed on the
# real board: 144 cards resting in done/install/push carry exactly this.
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

my $tmp = tempdir( CLEANUP => 1 );

# The browser move: ungated, exactly as TKT-426/452 leave it - needed only
# to strand an item behind on the way past, the same as t/1083's own
# required-action-stranded tests do; every other case here moves through
# the ordinary gated record_move.
sub browser_moved {
    my ( $tira, $root, $ref, $column, $type ) = @_;
    my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
    return $providers{move}->( { ref => $ref, column => $column, type => $type // 'ticket', _signed_in => 'claude' } );
}

sub board_at {
    my ($name) = @_;
    my $tira = Tira->new( clock => sub {'2026-09-27T09:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, $name );
    $tira->project_new(
        name => $name, dir => $root, members => ['claude'],
        columns => ['backlog, tests-red, implement, done'],
    );
    $tira->policy_add(
        project => $root, rule => 'required-unsatisfied', action => 'bridge-reminder',
    );
    return ( $tira, $root );
}

sub reported {
    my ( $tira, $root, $name ) = @_;
    my $pass = $tira->police_pass(
        project => $root,
        store   => File::Spec->catdir( $tmp, "store-$name" ),
        world   => {},
    );
    return $pass->{violations} // [];
}

# --- an unmet item for the card's own CURRENT column, resting in an ending
#     column, is reported - the exact gap the ticket measured ---------------
{
    my ( $tira, $root ) = board_at('resting-done');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Finished but still owing' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'tests-red' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'implement' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'done' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'done', item => 'Record the release note', status => 'pending' );

    my $violations = reported( $tira, $root, 'resting-done' );
    is( scalar @{$violations}, 1, 'a card resting in done with an unmet item for done itself is reported' );
    like( $violations->[0]{detail}, qr/Record the release note/, 'and the detail names the unmet item' );
    like( $violations->[0]{detail}, qr/done/, 'and the column it is still owed in' );
}

# --- the same card, once the item is marked done, produces no report -------
{
    my ( $tira, $root ) = board_at('settled-done');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Finished and clear' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'tests-red' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'implement' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'done' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'done', item => 'Record the release note', status => 'pending' );
    $tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref},
        id => 'REQ-001', status => 'done', command => ['noted'], proof => ['confirmed'] );

    is( scalar @{ reported( $tira, $root, 'settled-done' ) }, 0,
        'a card in done with nothing outstanding produces no report' );
}

# --- a WORKING column is not exempt either - nothing else watches an item
#     tagged to the card's own current column while it sits there ----------
{
    my ( $tira, $root ) = board_at('working');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Still busy but already owing' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'tests-red' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'implement' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'implement', item => 'Confirm the design first', status => 'pending' );

    my $violations = reported( $tira, $root, 'working' );
    is( scalar @{$violations}, 1,
        'a working column is not exempt either - an unmet item for the current column is reported there too' );
}

# --- an item tagged to a column the card has already left is stranded's
#     business, not this rule's - no double report -------------------------
{
    my ( $tira, $root ) = board_at('left-behind');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Left one behind' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'backlog', item => 'Fill in the fields', status => 'pending' );
    browser_moved( $tira, $root, $card->{ref}, 'implement', 'ticket' );

    is( scalar @{ reported( $tira, $root, 'left-behind' ) }, 0,
        "an item tagged to a column already left behind is required-action-stranded's business, not this one's" );
}

# --- an exempted item is not reported ---------------------------------------
{
    my ( $tira, $root ) = board_at('exempted');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Excused where it sits' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'tests-red' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'implement' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'done' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'done', item => 'Record the release note', status => 'pending' );
    $tira->record_update( project => $root, ref => $card->{ref}, author => 'claude',
        required_exempt => ['Record the release note'], exempt_reason => ['Not needed for this card'] );

    is( scalar @{ reported( $tira, $root, 'exempted' ) }, 0,
        'an item this card is exempt from is not reported' );
}

# --- a discarded card is exempt throughout, same as every other rule -------
{
    my ( $tira, $root ) = board_at('discarded');
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Set aside with work outstanding' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'tests-red' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'implement' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'done' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
        column => 'done', item => 'Record the release note', status => 'pending' );
    $tira->record_discard( author => 'claude', project => $root, ref => $card->{ref} );

    is( scalar @{ reported( $tira, $root, 'discarded' ) }, 0,
        'a discarded card is exempt throughout, the same as every other machine-watching rule' );
}

done_testing;

__END__

=head1 NAME

643-a-column-that-stopped-asking.t - a resting/ending column stops asking whether its own required items were ever met

=head1 DESCRIPTION

TKT-643. C<required-action-stranded> (TKT-612) reports an unmet required
item tagged to a column the card has already left BEHIND, but deliberately
exempts ending columns and never looks AT the card's own current column.
The CLI departure gate only fires on the way out of a column. So an item
attached to the column a card is currently resting in - working or ending -
was invisible to every check. C<required-unsatisfied> closes that: it
reports any record, in any column, still carrying an unmet required item
for that same column, honouring the same C<required_exempt> mechanism and
discard exemption every other required-action rule already does.

=cut
