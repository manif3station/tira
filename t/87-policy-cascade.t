#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-11T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Layered', dir => $root, members => ['michael', 'claude' ],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'LYS', epic_prefix => 'LYE', ticket_prefix => 'LYT',
);

my $one = $tira->create_record( project => $root, type => 'ticket', title => 'First' );
my $two = $tira->create_record( project => $root, type => 'ticket', title => 'Second' );
$tira->record_move(author => 'claude',  project => $root, ref => $_, column => 'implement' ) for $one->{ref}, $two->{ref};

sub applied {
    my ($ref) = @_;
    my $resolved = $tira->policy_resolve( project => $root, ref => $ref );
    return { map { $_->{rule} => $_ } @{$resolved} };
}

# --- a project-level policy applies to everything -------------------------

$tira->policy_add( project => $root, rule => 'wip-limit',
    column => 'implement', max => 5, action => 'bridge-reminder' );
is( applied( $one->{ref} )->{'wip-limit'}{max}, 5,
    'a policy set on the project applies to a card' );
is( applied( $two->{ref} )->{'wip-limit'}{max}, 5, 'and to every other card' );

# --- a board-level policy overrides the project ---------------------------

$tira->policy_add( project => $root, rule => 'wip-limit', type => 'ticket',
    column => 'implement', max => 3, action => 'bridge-reminder' );
is( applied( $one->{ref} )->{'wip-limit'}{max}, 3,
    'a policy on the board overrides the project' );

# --- a column-level policy overrides the board ----------------------------

$tira->policy_add( project => $root, rule => 'wip-limit', type => 'ticket',
    on_column => 'implement', column => 'implement', max => 2, action => 'bridge-reminder' );
is( applied( $one->{ref} )->{'wip-limit'}{max}, 2,
    'a policy on the column overrides the board' );

# --- and a card overrides the lot -----------------------------------------

$tira->policy_add( project => $root, rule => 'wip-limit', ref => $one->{ref},
    column => 'implement', max => 1, action => 'bridge-reminder' );
is( applied( $one->{ref} )->{'wip-limit'}{max}, 1,
    'a policy on the card wins over everything above it' );
is( applied( $two->{ref} )->{'wip-limit'}{max}, 2,
    'while another card is untouched by it, and still takes the column\'s' );

# --- overriding one rule leaves the others alone --------------------------

# The alternative - the most specific LIST wins outright - would let one
# exception switch everything else off, which is the kind of quiet failure this
# whole subsystem exists to catch.
$tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'card-stalled',
    before => 'verify', action => 'bridge-reminder' );
my $card_view = applied( $one->{ref} );
is( scalar keys %{$card_view}, 3,
    'a card that overrides one rule still has every other rule the project set' );
ok( $card_view->{'orphan-card'}, 'the project rules are still there' );
is( $card_view->{'wip-limit'}{max}, 1, 'with only the overridden one replaced' );

# --- falling back, level by level -----------------------------------------

my %levels = (
    card => { ref => $one->{ref} },
    column => { type => 'ticket', on_column => 'implement' },
    board => { type => 'ticket' },
);
for my $level (qw(card column board)) {
    my $before = applied( $one->{ref} )->{'wip-limit'}{max};
    my ($policy) = grep {
        my $p = $_;
        $p->{rule} eq 'wip-limit'
          && ( ( $levels{$level}{ref} // '' ) eq ( $p->{ref} // '' ) )
          && ( ( $levels{$level}{type} // '' ) eq ( $p->{type} // '' ) )
          && ( ( $levels{$level}{on_column} // '' ) eq ( $p->{on_column} // '' ) );
    } @{ $tira->policy_list( project => $root ) };
    ok( $policy, "the $level policy is there to be removed" ) or next;
    $tira->policy_remove( project => $root, id => $policy->{id} );
    my $after = applied( $one->{ref} )->{'wip-limit'}{max};
    isnt( $after, $before, "removing the $level policy falls back to the next one down" );
}
is( applied( $one->{ref} )->{'wip-limit'}{max}, 5,
    'and with all of them gone, the project\'s is what applies' );

# --- police uses what was resolved ----------------------------------------

# The resolution is worth nothing if evaluation ignores it, so this checks the
# rule that actually fires is the one that was resolved for that card.
$tira->policy_add( project => $root, rule => 'card-duration', column => 'implement',
    age => '10h', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'card-duration', ref => $one->{ref},
    column => 'implement', age => '1m', action => 'bridge-reminder' );
$now = '2026-08-11T09:30:00Z';
my @overdue = grep { $_->{rule} eq 'card-duration' }
  @{ $tira->policy_evaluate( project => $root ) };
is( scalar @overdue, 1, 'only the card with the shorter age is overdue' );
is( $overdue[0]{ref}, $one->{ref}, 'and it is the one that overrode the rule' );

# --- what police cannot resolve, it says ----------------------------------

# Guessing would make police wrong; silence would let an under-specified policy
# read as cover. So it says what it could not work out.
$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'a-column-that-does-not-exist', action => 'bridge-reminder' );
my $unresolved = $tira->policy_unresolved( project => $root );
is( scalar @{$unresolved}, 1, 'a policy naming a column that does not exist is reported' );
like( $unresolved->[0]{detail}, qr/a-column-that-does-not-exist/, 'naming what it could not find' );
like( $unresolved->[0]{detail}, qr/POL-/, 'and which policy said it' );

$tira->column_add( project => $root, type => 'ticket', name => 'a-column-that-does-not-exist' );
is_deeply( $tira->policy_unresolved( project => $root ), [],
    'and once the column exists it is resolved, with nothing left to say' );

done_testing;

__END__

=head1 NAME

87-policy-cascade.t - the smaller config is king

=head1 DESCRIPTION

A policy can be declared on the project, on a board, on a column or on a single
card, and the most specific one wins. That lets a project hold one card to a
different standard without weakening the rule for everybody, which is the only
way an exception stays visible instead of becoming a reason to delete the rule.

Resolution is per rule rather than per list. A card that overrides one rule
keeps every other rule the project declared - the alternative would let a single
exception silently switch everything else off, which is exactly the class of
quiet failure this subsystem was built to catch.

Falling back is checked level by level rather than only at the ends, because a
cascade that works at the top and the bottom and skips the middle looks correct
from either side.

The last section is police admitting what it cannot work out. A policy naming a
column that does not exist is neither guessed at nor ignored: guessing would
make police wrong, and silence would let an under-specified policy read as
cover.

=cut
