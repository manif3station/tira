#!/usr/bin/env perl
# wip-limit counted sows, epics and tickets together in one pool. An epic In
# Progress is not work being done on this board - per AT99 clause 1a-EPIC-3
# it is the permission state for its children, and it stays there for as
# long as its team is active. Counted in one pool with tickets, a handful of
# epics with children beneath them exhausted the whole ticket-concurrency
# budget just by existing, before a single ticket could be worked - the
# number that was right for a flat board of tickets was measuring a
# different population once a manager layer (sow/epic) exists above it.
# TKT-333.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tira = Tira->new( clock => sub { '2026-08-23T09:00:00Z' } );
my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Layered', dir => $root, members => ['claude'],
    columns => ['backlog, in-progress, done'],
    sow_prefix => 'LYS', epic_prefix => 'LYE', ticket_prefix => 'LYT',
);
$tira->policy_add( project => $root, rule => 'wip-limit',
    column => 'in-progress', max => 2, action => 'bridge-reminder' );

sub fired {
    return grep { $_->{rule} eq 'wip-limit' } @{ $tira->policy_evaluate( project => $root ) };
}

# --- one epic, and exactly max tickets: neither type alone exceeds the limit --

my @epics;
push @epics, $tira->create_record( project => $root, type => 'epic', title => 'The one manager' );
$tira->record_move( author => 'claude', project => $root, ref => $epics[0]{ref}, column => 'in-progress' );

my @tickets;
for my $n ( 1 .. 2 ) {
    my $card = $tira->create_record( project => $root, type => 'ticket', title => "Worker $n" );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'in-progress' );
    push @tickets, $card;
}

is( scalar( fired() ), 0,
    'one epic plus max tickets (2+2=4 combined, but neither type alone exceeds 2) stays silent' );

# --- a third ticket pushes the ticket count over, and it fires for tickets alone --

my $third = $tira->create_record( project => $root, type => 'ticket', title => 'Worker 3' );
$tira->record_move( author => 'claude', project => $root, ref => $third->{ref}, column => 'in-progress' );

{
    my @found = fired();
    is( scalar(@found), 1, 'the ticket overage fires exactly once' );
    like( $found[0]{detail}, qr/\b3\b/, 'saying how many tickets there are' );
    like( $found[0]{detail}, qr/\btickets\b/, 'and naming the type - tickets - explicitly' );
    like( $found[0]{detail}, qr/limit is 2/, 'and what the limit is' );
    unlike( $found[0]{detail}, qr/\bepics\b/, 'and it does not also claim epics are over, since only tickets are' );
}

# --- a third epic pushes the epic count over too, and it fires independently, per type --

my $second_epic = $tira->create_record( project => $root, type => 'epic', title => 'A second manager' );
$tira->record_move( author => 'claude', project => $root, ref => $second_epic->{ref}, column => 'in-progress' );
my $third_epic = $tira->create_record( project => $root, type => 'epic', title => 'A third manager' );
$tira->record_move( author => 'claude', project => $root, ref => $third_epic->{ref}, column => 'in-progress' );

{
    my @found = fired();
    is( scalar(@found), 2, 'both the ticket overage and the epic overage fire, independently' );
    my ($epic_finding)   = grep { $_->{detail} =~ /\bepics\b/ } @found;
    my ($ticket_finding) = grep { $_->{detail} =~ /\btickets\b/ } @found;
    ok( $epic_finding,   'one finding names epics' );
    ok( $ticket_finding, 'the other names tickets' );
    like( $epic_finding->{detail}, qr/\b3\b/, 'the epic finding counts only the 3 epics' );
    like( $ticket_finding->{detail}, qr/\b3\b/, 'the ticket finding counts only the 3 tickets' );
}

done_testing;

__END__

=head1 NAME

336-a-manager-that-crowds-the-workers.t - wip-limit counts within a record kind

=head1 DESCRIPTION

C<wip-limit> counted sows, epics and tickets together in one pool. An epic
C<In Progress> is the permission state for its children on this board (AT99
clause 1a-EPIC-3), not work being done, and stays there for as long as its
team is active - so a handful of epics with children beneath them exhausted
the whole ticket-concurrency budget just by existing. C<wip-limit> now
counts and reports each record kind separately, so a manager layer above
the tickets cannot consume a ticket's budget by existing, and the finding
names the kind it is reporting. TKT-333.

=cut
