#!/usr/bin/env perl
# A board can have more than one way of being finished.
#
# card-unassigned decides which columns are work by asking which are protected -
# every board is created with backlog and discard protected - and treating
# everything else as somewhere work happens, with `done` reasoned about by name.
#
# That holds for a board with one finished column. developer-dashboard has
# three, because their SDLC distinguishes work that ships from work that cannot:
#
#     done-not-released   finished, waiting for a release
#     admin-done          finished, ships nothing at all
#     release-to-pause    finished and published
#
# None is protected, so within one minute of declaring the rule it fired on nine
# finished cards, telling them to assign somebody to work that shipped days
# before. Nine notes in one pass, all wrong, on the first run.
#
# The reasoning that produced the rule is on the card that shipped it and was
# right: card-metrics could already express this per column, and was rejected
# because a policy naming one column stops covering the board the moment
# somebody adds another. What was wrong was the assumption that protected
# answers the question. Protected means Tira owns this column. It does not mean
# work does not happen here.
#
# So a board says which of its columns are endings, and the rule asks. A board
# that has said nothing behaves exactly as before, because no board should
# change underneath anybody.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-14T14:00:00Z'} );
my $store = File::Spec->catdir( $tmp, 'police' );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Three endings', dir => $root, members => ['michael', 'claude' ],
    columns => ['backlog, doing, done-not-released, admin-done, release-to-pause'],
    sow_prefix => 'TES', epic_prefix => 'TEE', ticket_prefix => 'TET',
);

sub card_in {
    my ( $title, $column ) = @_;
    my $card = $tira->create_record( project => $root, type => 'ticket', title => $title );
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => $column );
    return $card->{ref};
}

sub unassigned {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ map { $_->{ref} } grep { $_->{rule} eq 'card-unassigned' } @{ $pass->{violations} } ];
}

my $working  = card_in( 'Being worked with nobody on it', 'doing' );
my $waiting  = card_in( 'Finished, waiting for a release', 'done-not-released' );
my $admin    = card_in( 'Finished, ships nothing',         'admin-done' );
my $released = card_in( 'Finished and published',          'release-to-pause' );

$tira->policy_add( project => $root, rule => 'card-unassigned', action => 'bridge-reminder' );

# --- what they saw -----------------------------------------------------------------

my $before = unassigned();
is( scalar @{$before}, 4,
    'every finished card is reported alongside the one being worked, which is what they measured' );

# --- a board saying which columns are endings ----------------------------------------

for my $ending (qw(done-not-released admin-done release-to-pause)) {
    $tira->column_update( project => $root, type => 'ticket', name => $ending, terminal => 1 );
}

my $after = unassigned();
is_deeply( $after, [$working],
    'only the card actually being worked is reported once the board says where work ends' );

# --- and a column added tomorrow is still covered --------------------------------------
#
# The reason this is a property of the board rather than an argument on the
# policy. A policy naming its columns stops covering the board the moment
# somebody adds one, silently.

$tira->column_add( project => $root, type => 'ticket', name => 'reviewing' );
my $later = card_in( 'In a column nobody had thought of', 'reviewing' );
is_deeply( [ sort @{ unassigned() } ], [ sort $working, $later ],
    'a column added after the policy was declared is still watched' );

# --- while a board that has said nothing is unchanged ------------------------------------
#
# No board changes underneath anybody. An ordinary board has one ending called
# done and has never marked anything, and it must behave exactly as it did.

my $ordinary = File::Spec->catdir( $tmp, 'ordinary' );
$tira->project_new(
    name => 'Ordinary', dir => $ordinary, members => ['michael', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ORS', epic_prefix => 'ORE', ticket_prefix => 'ORT',
);
my $plain_store = File::Spec->catdir( $tmp, 'police-ordinary' );
my $held = $tira->create_record( project => $ordinary, type => 'ticket', title => 'Being worked' );
$tira->record_move(author => 'claude',  project => $ordinary, ref => $held->{ref}, column => 'implement' );
my $finished = $tira->create_record( project => $ordinary, type => 'ticket', title => 'Finished' );
$tira->record_move(author => 'claude',  project => $ordinary, ref => $finished->{ref}, column => 'done' );
$tira->policy_add( project => $ordinary, rule => 'card-unassigned', action => 'bridge-reminder' );

my $pass = $tira->police_pass( project => $ordinary, store => $plain_store, world => {} );
my @plain = map { $_->{ref} } grep { $_->{rule} eq 'card-unassigned' } @{ $pass->{violations} };
is_deeply( \@plain, [ $held->{ref} ],
    'a board that has marked nothing still treats done as an ending, exactly as before' );

# --- and the columns asked about are the card's own --------------------------------------
#
# The rule read the ticket board's columns whatever kind of card it was looking
# at. A board whose epics end somewhere the tickets do not would have been
# judged against the wrong list.

$tira->column_add( project => $root, type => 'epic', name => 'epic-done' );
$tira->column_update( project => $root, type => 'epic', name => 'epic-done', terminal => 1 );
my $epic = $tira->create_record( project => $root, type => 'epic', title => 'A finished epic' );
$tira->record_move(author => 'claude',  project => $root, ref => $epic->{ref}, column => 'epic-done' );
ok( !scalar( grep { $_ eq $epic->{ref} } @{ unassigned() } ),
    'an epic in its own board\'s ending is not reported against the ticket board\'s columns' );

# --- the flag is readable, because a board that cannot be read cannot be checked ------------

my ($marked) = grep { $_->{name} eq 'admin-done' }
  @{ $tira->column_list( project => $root, type => 'ticket' ) };
ok( $marked->{terminal}, 'a column that was marked an ending says so when the board is read' );

my ($not) = grep { $_->{name} eq 'doing' }
  @{ $tira->column_list( project => $root, type => 'ticket' ) };
ok( !$not->{terminal}, 'and one that was not does not' );

done_testing;

__END__

=head1 NAME

163-a-board-with-more-than-one-ending.t - a board can have more than one ending

=head1 DESCRIPTION

C<card-unassigned> inferred which columns are work from protected-ness, which
distinguishes the two columns Tira owns rather than the columns where work
happens. A board with three finished columns had the rule fire on nine finished
cards within a minute of declaring it.

A board now says which of its columns are endings and the rule asks. A board that
has marked nothing behaves as before, a column added later is still watched
without being named on the policy, and the columns consulted are those of the
card's own board rather than the ticket board's.

=cut
