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

# --- a card moved between two record_list calls in one pass is not a ------
# --- duplicate, even though the eager cache sees two different paths ------
#
# TKT-1116's first draft flagged this as a duplicate and it broke live on
# the real board within the hour: policy_evaluate calls record_list a
# SECOND time from inside one rule's own block (the task-work loop, ~line
# 9668), and a card moved between the first and second call - ordinary on
# a board being worked while the pass runs - resolved to two different
# paths within one pass. The eager cache must let the later path win
# rather than calling that a duplicate; only _record_data's own lazy,
# single-instant $walk is the authority on a genuine one.

{
    my $tmp2 = tempdir( CLEANUP => 1 );
    my $now2 = '2026-09-06T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now2} );
    my $root = File::Spec->catdir( $tmp2, 'proj' );
    $tira->project_new(
        name => 'Moved Mid Pass', dir => $root, members => ['claude'],
        columns    => ['backlog, implement, done'],
        sow_prefix => 'MMS', epic_prefix => 'MME', ticket_prefix => 'MMT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card that will move between two record_list calls' );

    # The mechanism isolated from any particular rule's own call shape,
    # the same way t/582's own second block isolates _police_path_cache
    # from policy_evaluate: two direct record_list calls inside one shared
    # path cache, with a real move between them - exactly what
    # policy_evaluate's own initial walk and task-card-mismatch's own
    # second, bare record_list(project=>$root) call (~line 9668) produce on
    # a board being worked while the pass runs.
    # The lookup has to happen INSIDE the same _police_path_cache scope -
    # _path_cache reverts to undef the moment that block returns, which
    # would hide the bug entirely (a first draft of this test checked
    # afterwards and passed against the unfixed code for exactly that
    # reason: with no active cache, the duplicate flag no longer matters).
    my $found;
    my $error;
    $tira->_police_path_cache( sub {
        $tira->record_list( project => $root, include_discard => 1 );
        $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement',
            author => 'claude' );
        $tira->record_list( project => $root );
        $found = eval { $tira->_record_data( project => $root, ref => $card->{ref} ); 1 };
        $error = $@;
    } );

    ok( $found, 'a card moved between two record_list calls in the same pass is still readable '
          . 'afterwards - moving mid-pass is not a duplicate, even though the eager cache saw it '
          . 'at two different paths' )
      or diag($error);
}

# --- a ref found TWICE BY ONE WALK still refuses - a genuine duplicate ------
#
# Codex review, TKT-1120: removing cross-call comparison entirely would also
# have silently accepted a real on-disk duplicate encountered by the eager
# walk, since a populated cache bypasses _record_data's own lazy $walk (and
# its @found > 1 check) on a hit. File::Find visits the WHOLE tree in one
# record_list call, so two files sharing a ref are both seen within that
# same call regardless of which the pass happens to ask about first - that
# is what distinguishes a genuine duplicate from a card that merely moved
# between two SEPARATE calls.

{
    my $tmp3 = tempdir( CLEANUP => 1 );
    my $now3 = '2026-09-06T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now3} );
    my $root = File::Spec->catdir( $tmp3, 'proj' );
    $tira->project_new(
        name => 'Genuine Duplicate', dir => $root, members => ['claude'],
        columns    => ['backlog, implement, done'],
        sow_prefix => 'GDS', epic_prefix => 'GDE', ticket_prefix => 'GDT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card about to be duplicated on disk' );
    my $original = File::Spec->catfile( $root, '.tira', 'ticket', 'backlog', "$card->{ref}.json" );
    my $copy = File::Spec->catfile( $root, '.tira', 'ticket', 'implement', "$card->{ref}.json" );
    mkdir File::Spec->catdir( $root, '.tira', 'ticket', 'implement' );
    require File::Copy;
    File::Copy::copy( $original, $copy ) or die "copy failed: $!";

    my ( $found, $error );
    $tira->_police_path_cache( sub {
        $tira->record_list( project => $root, include_discard => 1 );
        $found = eval { $tira->_record_data( project => $root, ref => $card->{ref} ); 1 };
        $error = $@;
    } );

    ok( !$found, 'a ref found twice by the SAME record_list walk still refuses when looked up, '
          . 'a genuine board fault the eager cache must not silently pick one side of' );
    like( $error // '', qr/Duplicate record/, 'naming it a duplicate' );
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
