#!/usr/bin/env perl
# TKT-1116. TKT-978 (t/582) made a REPEATED lookup of the same ref within one
# pass free, but the FIRST lookup of every distinct ref still pays its own
# File::Find walk - and _police_pass_body already calls record_list(
# include_discard=>1) before any rule runs, which walks every card on the
# board exactly once to build its own listing. That walk already knows every
# card's path; _record_data's later per-ref walk rediscovers what record_list
# already found.
#
# On his live board this is the whole remaining gap TKT-978 left: 349 cards,
# ~1,384 distinct-ref lookups, each paying its own 0.0095s walk because
# nothing primed the cache before the rules asked. This test proves the FIRST
# lookup of a pre-existing card, inside a real pass, costs zero walks -
# because record_list's own walk already seeded the path cache.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;
use Tira::CLI::Police;

# Same TG-safety guard as t/582: this fixture enables notify_moves, which is
# exactly what would let a live TELEGRAM_BOT_TOKEN reach a real chat.
delete local $ENV{TELEGRAM_BOT_TOKEN};
delete local $ENV{TELEGRAM_CHATID};

# Counts every board walk, attributed to the ref _record_data was asked
# about - the same instrument t/582 built, reused here so both files fail the
# same way if the counter itself ever stops counting.
our $current_ref;
my %walks;
my $walks_total = 0;
{
    no warnings 'redefine';
    my $find = \&Tira::find;
    *Tira::find = sub {
        $walks_total++;
        $walks{ $current_ref // '?' }++ if defined $current_ref;
        return $find->(@_);
    };

    my $record_data = \&Tira::_record_data;
    *Tira::_record_data = sub {
        my ( $self, %args ) = @_;
        local $current_ref = $args{ref} // '?';
        $walks{$current_ref} += 0;
        return $record_data->( $self, %args );
    };
}

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-09-06T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'store' );
$tira->project_new(
    name => 'Already Answered', dir => $root, members => ['claude'],
    columns    => ['backlog, implement, done'],
    sow_prefix => 'AAS', epic_prefix => 'AAE', ticket_prefix => 'AAT',
);
mkdir File::Spec->catdir( $root, '.git' );

$tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'agent-still', action => 'bridge-reminder', age => '10m' );
$tira->notify_moves( project => $root, enabled => 1 );

my @refs;
for my $i ( 1 .. 4 ) {
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => "a pre-existing card ($i)" );
    push @refs, $card->{ref};
}

$now = '2026-09-06T09:30:00Z';
$tira->record_move( project => $root, ref => $_, column => 'implement', author => 'claude' )
  for @refs;

$now = '2026-09-06T10:00:00Z';
%walks       = ();
$walks_total = 0;
$tira->police_pass( project => $root, store => $store,
    world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );

diag( sprintf 'walks_total %d over %d refs asked about', $walks_total, scalar keys %walks );

cmp_ok( scalar keys %walks, '>=', 2,
    'the pass asked about more than one pre-existing card by ref, so there is something '
      . 'to measure' );

my @walked = grep { $walks{$_} > 0 } keys %walks;
is_deeply( \@walked, [],
    'and NOT ONE of them cost a walk on its first lookup either - record_list already '
      . 'walked the whole board before any rule ran, and that walk is what should have '
      . 'seeded the path cache' )
  or diag( 'walked at least once: ' . join( ', ', map { "$_ => $walks{$_}" } sort @walked ) );

# --- a genuine duplicate found by record_list's own walk still dies -------
#
# The eager index must not silently pick whichever path record_list happens
# to see last: a ref filed twice is a real board fault, and _record_data has
# to keep refusing it the moment anything actually asks, exactly as the
# lazy $walk inside it already does.

{
    my $tmp2  = tempdir( CLEANUP => 1 );
    my $now2  = '2026-09-06T09:00:00Z';
    my $tira  = Tira->new( clock => sub {$now2} );
    my $root  = File::Spec->catdir( $tmp2, 'proj' );
    my $store = File::Spec->catdir( $tmp2, 'store' );
    $tira->project_new(
        name => 'Duplicated On Disk', dir => $root, members => ['claude'],
        columns    => ['backlog, implement, done'],
        sow_prefix => 'DOS', epic_prefix => 'DOE', ticket_prefix => 'DOT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    $tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card about to be duplicated on disk' );
    my $original = File::Spec->catfile( $root, '.tira', 'ticket', 'backlog', "$card->{ref}.json" );
    my $copy = File::Spec->catfile( $root, '.tira', 'ticket', 'implement', "$card->{ref}.json" );
    mkdir File::Spec->catdir( $root, '.tira', 'ticket', 'implement' );
    require File::Copy;
    File::Copy::copy( $original, $copy ) or die "copy failed: $!";

    my $world = Tira::CLI::Police::police_world( tira => $tira, project => $root );
    eval { $tira->police_pass( project => $root, store => $store, world => $world ) };

    my $found = eval { $tira->_record_data( project => $root, ref => $card->{ref} ); 1 };
    ok( !$found, 'a ref record_list found at two different paths still refuses when looked up '
          . 'after the pass, the same as a lazily-walked duplicate always has' );
    like( $@ // '', qr/Duplicate record/,
        'naming it a duplicate, not silently returning whichever of the two paths the eager '
          . 'walk happened to see last' );
}

done_testing();

__END__

=head1 NAME

1117-a-lookup-record-list-already-answered.t - the first lookup of a pre-existing card costs nothing either

=head1 DESCRIPTION

TKT-1116. TKT-978 (t/582) made a second, repeated lookup of the same ref
within one pass free, but the first lookup of each distinct ref still ran
its own C<File::Find> walk - despite C<_police_pass_body> already calling
C<record_list(include_discard=E<gt>1)> first, which walks the whole board
once. This asserts that walk is reused: after a real pass runs, no
pre-existing card's C<_record_data> lookup shows a single walk charged to it.

=cut
