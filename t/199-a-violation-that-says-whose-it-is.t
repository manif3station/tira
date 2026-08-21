#!/usr/bin/env perl
# A violation says which board it belongs to.
#
# Found on 2026-08-15 by two people looking up the same number and getting
# different problems. TKT-206 quoted VIO-0453 meaning card-sandbox-missing on
# DD-532, from developer-dashboard; the owner looked up VIO-0453 and found
# column-skipped on M5T-365, an mt5 card. Both were right. Every board's
# enforcement store counts its own violations from one, so the number identifies
# nothing outside the board that issued it.
#
# Numbering is not the fault and is not changed here. Within a board the number
# does exactly its job: one lasting problem reads as one problem getting louder
# rather than as noise repeating, which is why it exists. What went wrong is
# that the number escaped the board - into reports filed through
# tira.dev.found.bug_or_improvement, into questions between projects, into what
# an agent pastes to its owner - and three projects now file into this board, so
# a number in a report is routinely read by somebody holding a different one.
#
# The failure is silent, which is what makes it worth a card: the wrong
# violation reads as a perfectly good answer, and neither party has any way to
# notice they are discussing different things.
#
# His decision, answering Q-037: a field on the bridge line, at the end, plus
# naming the board in the replay header. At the end because mt5-ai and
# developer-dashboard have both written tooling against this line, and a parser
# splitting the first N fields must be unaffected. Making the numbers globally
# unique was rejected - a board's store is its own, and coordinating them is
# what this design avoids.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );

sub board {
    my ( $name, $prefix ) = @_;
    my $tira = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, lc $name );
    $tira->project_new(
        name => $name, dir => $root, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => "${prefix}S", epic_prefix => "${prefix}E", ticket_prefix => $prefix,
    );
    $tira->policy_add( project => $root, rule => 'discard-unexplained',
        action => 'bridge-reminder' );
    my $ref = $tira->create_record( project => $root, type => 'ticket',
        title => 'Set aside without a word' )->{ref};
    $tira->record_move(author => 'claude',  project => $root, ref => $ref, column => 'discard' );

    my $store = File::Spec->catdir( $tmp, "police-" . lc $name );
    my $pass = $tira->police_pass( project => $root, store => $store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    $tira->bridge_write( store => $store, project => $root,
        violations => $pass->{violations}, settled => $pass->{settled} );
    return ( $tira, $store, $ref, $pass );
}

# --- two boards, each with its own first violation ------------------------------------

my ( $one, $one_store, $one_ref, $one_pass ) = board( 'Alpha', 'ALP' );
my ( $two, $two_store, $two_ref, $two_pass ) = board( 'Beta',  'BET' );

is( $one_pass->{violations}[0]{id}, $two_pass->{violations}[0]{id},
    'both boards issue the same number, because each store counts its own from one' );

# --- and the lines can be told apart ---------------------------------------------------

my ($alpha) = grep { /VIO-/ } @{ $one->bridge_backlog( store => $one_store, lines => 50 ) };
my ($beta)  = grep { /VIO-/ } @{ $two->bridge_backlog( store => $two_store, lines => 50 ) };

like( $alpha, qr/Alpha/, 'the line from one board names that board' );
like( $beta,  qr/Beta/,  'and the line from the other names the other' );
isnt( $alpha, $beta, 'so two lines carrying the same number are not the same line' );

# --- at the end, because parsers exist ---------------------------------------------------
#
# His condition. A reader splitting the first N fields of a bridge line must see
# exactly what it saw before.

{
    my @fields = split / \| /, $alpha;
    like( $fields[0], qr/\A2026-/, 'the first field is still the time' );
    like( $fields[1], qr/\A[A-Z]+\z/, 'the second is still the tone' );
    like( $fields[-1], qr/Alpha/, 'and the board is the last field, after the fix' );
}

# --- and the replay header names it too ---------------------------------------------------

{
    my ($header) = grep { /replaying/ } @{ $one->bridge_backlog( store => $one_store, lines => 50 ) };
    ok( $header, 'a replay introduces itself' );
    like( $header, qr/Alpha/, 'naming the board whose history is being replayed' );
}

# --- while numbering within a board is untouched ---------------------------------------------
#
# The half that must not change. One lasting problem still keeps one number and
# gets louder, which is the whole reason the number exists.

{
    my $again = $one->police_pass( project => File::Spec->catdir( $tmp, 'alpha' ),
        store => $one_store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is( $again->{violations}[0]{id}, $one_pass->{violations}[0]{id},
        'the same problem keeps the same number on the next pass' );
}

done_testing;

__END__

=head1 NAME

199-a-violation-that-says-whose-it-is.t - a number identifies its board

=head1 DESCRIPTION

Every board's enforcement store counts its violations from one, so C<VIO-0453>
on one board and C<VIO-0453> on another are unrelated problems - and two people
looked up that number, got different answers, and had no way to notice. The
bridge line now carries the board at the end, where a parser splitting the first
fields is unaffected, and the replay header names it as well.

Numbering within a board is unchanged: one lasting problem keeps one number.

=cut
