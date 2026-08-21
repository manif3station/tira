#!/usr/bin/env perl
# Saying one column is terminal is a statement about that column.
#
# Reported by mt5-ai as background to the discard fault, and it is the more
# expensive half. Tira treats done as where work ends while nothing is marked
# terminal. Marking ONE other column terminal switched that off entirely, and on
# their board it produced 171 card-unassigned violations in a single police
# pass. They reverted it and have marked nothing since - which is why their
# discard column was protected and not an ending, which is the shape that made
# tira.next offer discarded cards.
#
# Measured here before anything was changed, on twenty finished cards: 0
# findings before, 20 after, and tira.column.endings stopped naming done at all.
# Their 171 is this at their size.
#
# The default is there to be right about the common shape. A board correcting it
# in one place has not withdrawn it everywhere, and nothing warned that it had -
# the cost arrives as a wall of findings about cards nobody touched.
#
# The flag is already three-valued: unset, terminal, or explicitly not terminal.
# So the board can still say done is not an ending; it just has to say it, which
# is the difference between a default and a trap.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $tira  = Tira->new( clock => sub {'2026-08-17T09:00:00Z'} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Terminal', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done, released'],
    sow_prefix => 'TMS', epic_prefix => 'TME', ticket_prefix => 'TMT',
);
$tira->policy_add( project => $root, rule => 'card-unassigned', action => 'log-only' );

for my $i ( 1 .. 20 ) {
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => "Finished, and nobody's any more $i", priority => 3 );
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'done' );
}

sub findings {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return scalar grep { ( $_->{rule} // '' ) eq 'card-unassigned' }
      @{ $pass->{violations} };
}

sub ends_in_done {
    return scalar grep { $_ eq 'done' }
      @{ $tira->column_endings( project => $root, type => 'ticket' ) };
}

# --- the board as it starts ----------------------------------------------------

is( findings(), 0, 'twenty finished cards are not reported, because done is where work ends' );
ok( ends_in_done(), 'and the board says so' );

# --- and after saying something true about a different column ------------------
#
# The whole card. Nothing about done changes, nothing about the twenty cards
# changes, and one other column is marked as an ending.

{
    $tira->column_update( project => $root, type => $_, name => 'released', terminal => 1 )
      for qw(sow epic ticket);

    is( findings(), 0,
        'marking another column terminal does not start reporting cards in done' );
    ok( ends_in_done(),
        'and done is still where work ends, because nothing said otherwise' );

    ok( scalar grep { $_ eq 'released' }
          @{ $tira->column_endings( project => $root, type => 'ticket' ) },
        'while the column that was marked is an ending too, which is what marking it meant' );
}

# --- proved by putting the all-or-nothing default back -------------------------
#
# Done first, while done is still unset, because the flag cannot be unset once
# it is written - which is why the reporting board reverted by hand rather than
# by clearing anything. One marked column switching off the assumption for every
# other is what cost them 171 findings in a pass.

{
    no warnings 'redefine';
    local *Tira::_resting_columns = sub {
        my ( $self, $where, $type ) = @_;
        my $columns = eval { $self->column_list( project => $where, type => $type ) } || [];
        my %resting = map { $_->{name} => 1 }
          grep { $_->{protected} || $_->{terminal} || !$_->{watched} } @{$columns};
        $resting{done} = 1 if !grep { $_->{terminal} } @{$columns};
        return \%resting;
    };

    is( findings(), 20,
        'the all-or-nothing default reports all twenty again, which is the fault at this size' );
}

# --- and the board can still say done is not an ending -------------------------
#
# The difference between a default and a trap. The flag has three values, so
# saying it is a thing a board can do - it just has to say it.

{
    $tira->column_update( project => $root, type => $_, name => 'done', terminal => 0 )
      for qw(sow epic ticket);

    ok( !ends_in_done(), 'a board that says done is not an ending is believed' );
    is( findings(), 20,
        'and its finished cards are judged as live work, which is what it asked for' );
}

# --- a board that has no done column at all -------------------------------------
#
# The case the first attempt at this got wrong, and it was caught by t/238
# rather than by anything here - which is the reason it is here now. A board can
# name its ending and have no done column, and assuming one puts a column in the
# answer that does not exist on the board.

{
    my $named = File::Spec->catdir( $tmp, 'named' );
    $tira->project_new(
        name => 'Named', dir => $named, members => ['claude'],
        columns => ['backlog, implement, verify, shipped'],
        sow_prefix => 'NDS', epic_prefix => 'NDE', ticket_prefix => 'NDT',
    );
    $tira->column_update( project => $named, type => $_, name => 'shipped', terminal => 1 )
      for qw(sow epic ticket);

    is_deeply( $tira->column_endings( project => $named, type => 'ticket' ), ['shipped'],
        'a board that names its ending and has no done column gets exactly that' );

    my $unmarked = File::Spec->catdir( $tmp, 'unmarked' );
    $tira->project_new(
        name => 'Unmarked', dir => $unmarked, members => ['claude'],
        columns => ['backlog, implement, verify, shipped'],
        sow_prefix => 'UNS', epic_prefix => 'UNE', ticket_prefix => 'UNT',
    );

    is_deeply( $tira->column_endings( project => $unmarked, type => 'ticket' ), ['done'],
        'while one that marks nothing still falls back to done, as it always did' );
}

done_testing;

__END__

=head1 NAME

256-marking-one-column-terminal.t - a default that is not withdrawn by one correction

=head1 DESCRIPTION

Marking one column terminal switched off the assumption that C<done> is where
work ends, so every finished card on the board became live work at once - 171
findings in a single pass on the board that reported it, 20 of 20 in the
fixture here.

C<done> is now assumed to be an ending unless the board says otherwise, which it
can still do: the flag has always had three values, and saying it out loud is
the difference between a default and a trap.

=cut
