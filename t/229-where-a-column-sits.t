#!/usr/bin/env perl
# Where a column sits, worked out once.
#
# Two rules need the board's column order. card-stalled asks whether a card is
# before a marker, and builds a list of names to find two indices in.
# checklist-unmoved asks whether a move went backwards, and builds a map of
# name to position. Different questions, one fact underneath, derived twice.
#
# I wrote the second an hour before this, fixing a different card, and had
# raised a card about exactly this shape twenty minutes before that - a helper
# answering where work ends while two rules rebuilt it inline. Finding the same
# fault in the code I wrote next is the argument for hunting rather than
# waiting for a report.
#
# They agree today, which is the condition under which nobody notices there are
# two. Proved the way the last one was: the helper is replaced for the length
# of the test and both rules have to follow. A rule with its own copy cannot.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use lib 't/lib';
use Suite qw(engine_source);

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $store = File::Spec->catdir( $tmp, 'store' );
my $now   = '2026-08-16T09:00:00Z';

my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Ordered', dir => $root, members => ['claude'],
    columns => ['backlog, implement, review, done'],
    sow_prefix => 'ORS', epic_prefix => 'ORE', ticket_prefix => 'ORT',
);
$tira->policy_add( project => $root, rule => 'checklist-unmoved',
    action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Sent back for more work' );
$tira->checklist_add( author => 'claude', project => $root, ref => $card->{ref},
    item => 'The work itself', status => 'To Do' );

$now = '2026-08-16T10:00:00Z';
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );
$now = '2026-08-16T11:00:00Z';
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'review' );

sub reported {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return scalar grep { ( $_->{rule} // '' ) eq 'checklist-unmoved' }
      @{ $pass->{violations} };
}

# --- as the board reads today ----------------------------------------------
#
# review comes after implement, so this was a move forward with nothing ticked
# and the rule has something to say. Asserted first, so what follows is a
# changed answer rather than a rule with nothing to say about this card.

ok( reported(), 'a card moved on with nothing ticked is reported' );

# --- and when where a column sits changes ----------------------------------
#
# The order is turned upside down for the length of this block. Nothing about
# the board or the card changes; only the answer to where a column sits. A rule
# that asks follows, and a rule that works it out for itself carries on.

{
    no warnings 'redefine';
    local *Tira::_column_positions = sub {
        my ( $self, $root, $type ) = @_;
        return { done => 0, review => 1, implement => 2, backlog => 3 };
    };

    is( reported(), 0,
        'and stops being reported when that move counts as going backwards' );
}

# --- and back again ---------------------------------------------------------

ok( reported(), 'and is reported again once the order reads as it did before' );

# --- the other rule asks the same question ----------------------------------
#
# card-stalled asks whether a card is before a marker. It is a different
# question about the same fact, and it has to come from the same place or the
# two can disagree about a board neither of them changed.

{
    my $text = engine_source();

    my ($before) = $text =~ /(sub _policy_before_column \{.*?\n\})/s;
    ok( $before, 'the rule that asks whether a card is before a marker is there' );
    like( $before // '', qr/_column_positions/,
        'and asks where a column sits rather than working it out again' );
}

done_testing;

__END__

=head1 NAME

229-where-a-column-sits.t - one order, two questions

=head1 DESCRIPTION

C<_policy_before_column> built a list of names to find two indices in;
C<checklist-unmoved> built a map of name to position. Two derivations of one
fact, agreeing, which is why nobody would have noticed until a change reached
one of them.

Proved by replacing the answer rather than by reading the code: a rule that
asks follows, a rule with its own copy cannot.

=cut
