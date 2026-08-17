#!/usr/bin/env perl
# Work the board abandoned is not work that is waiting.
#
# Found by using the command rather than by reading it. 2.43 shipped tira.next
# in the morning; the first real call after installing it, on this project's own
# board, returned 24 cards of which 15 were discarded - and the single card it
# named as the answer was TKT-240, discarded on 2026-08-15.
#
# One word in the definition of waiting. work_order counts a card as waiting if
# its column is protected and not an ending, and discard is protected: True,
# terminal: None. So every discarded card qualified.
#
# It reaches the rule as well, because TKT-274 pointed priority-skipped at
# work_order in that same release: the rule can now name a discarded card as one
# that was passed over. That is the cost of one definition serving both, and it
# is still the right trade - one change fixes both, and they cannot drift.
#
# police never had this problem and shows where the fix goes: it loads every
# card with include_discard and filters discard out before any rule sees it.
# work_order asked record_list directly and inherited none of that.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-17T09:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Abandoned', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ABS', epic_prefix => 'ABE', ticket_prefix => 'ABT',
);
$tira->policy_add( project => $root, rule => 'priority-skipped',
    action => 'bridge-reminder' );

my $abandoned = $tira->create_record( project => $root, type => 'ticket',
    title => 'Started, thought better of, discarded', priority => 5 );
$now = '2026-08-17T10:00:00Z';
my $waiting = $tira->create_record( project => $root, type => 'ticket',
    title => 'Actually waiting to be worked', priority => 4 );
$now = '2026-08-17T11:00:00Z';
my $lesser = $tira->create_record( project => $root, type => 'ticket',
    title => 'Waiting, and less urgent', priority => 2 );

# --- while it is only a card, it is the answer --------------------------------
#
# Asserted before it is discarded, so what follows is the discarding and not a
# card the board never had an opinion about.

is( $tira->work_order( project => $root )->[0]{ref}, $abandoned->{ref},
    'the top-priority card is the answer while it is still real work' );

# --- and once it is discarded, it is not --------------------------------------

$tira->record_move( project => $root, ref => $abandoned->{ref}, column => 'discard' );

{
    my $order = $tira->work_order( project => $root );

    is( $order->[0]{ref}, $waiting->{ref},
        'the answer is the highest card still waiting, not the discarded one' );

    my %offered = map { $_->{ref} => 1 } @{$order};
    ok( !$offered{ $abandoned->{ref} },
        'and the discarded card is not offered anywhere in the queue' );

    is_deeply( [ map { $_->{ref} } @{$order} ],
        [ $waiting->{ref}, $lesser->{ref} ],
        'while the cards that are genuinely waiting are still there, in order' );
}

# --- and the rule does not name it either -------------------------------------
#
# The half that made this worth a card of its own rather than a note. A rule
# that says "you are working this while that waits" about a card the board
# abandoned is asking for work nobody wants done.

{
    $tira->record_move( project => $root, ref => $lesser->{ref}, column => 'implement' );

    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    my @skipped = grep { ( $_->{rule} // '' ) eq 'priority-skipped' }
      @{ $pass->{violations} };

    ok( scalar @skipped, 'working the lesser card while a real one waits is still reported' );
    like( $skipped[0]{detail} // '', qr/\Q$waiting->{ref}\E/,
        'naming the card that is waiting' );
    unlike( $skipped[0]{detail} // '', qr/\Q$abandoned->{ref}\E/,
        'and never the one the board abandoned' );
}

# --- proved by putting the fault back ------------------------------------------
#
# The definition 2.43 shipped: protected, not an ending. discard is both, so the
# discarded card is the answer again - which is exactly what the board returned
# on the first real call.

{
    no warnings 'redefine';
    local *Tira::work_order = sub {
        my ( $self, %args ) = @_;
        my $where = $self->discover_project(%args);
        my @all;
        for my $type (qw(sow epic ticket)) {
            my $ends = $self->_ending_columns( $where, $type );
            my $columns = eval { $self->column_list( project => $where, type => $type ) } || [];
            my %here = map { $_->{name} => 1 }
              grep { $_->{protected} && !$ends->{ $_->{name} } } @{$columns};
            my $records = eval { $self->record_list( project => $where, type => $type ) } || [];
            push @all, grep { defined $_->{priority} && $here{ $_->{column} // '' } }
              @{$records};
        }
        return [ sort { $b->{priority} <=> $a->{priority} } @all ];
    };

    is( $tira->work_order( project => $root )->[0]{ref}, $abandoned->{ref},
        'the shipped definition makes the discarded card the answer again' );
}

done_testing;

__END__

=head1 NAME

254-a-discarded-card-is-not-waiting.t - work the board abandoned is not waiting

=head1 DESCRIPTION

C<work_order> counted a card as waiting if its column was protected and not an
ending. C<discard> is both, so every discarded card was offered: on this
project's own board, 15 of the 24 cards C<tira.next> returned, including the one
it named as the answer.

Because C<priority-skipped> asks the same method, the rule could name a
discarded card as one that was passed over. Both are fixed by the one
exclusion, in the shape C<police> already uses.

=cut
