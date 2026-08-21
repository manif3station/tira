#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tira = Tira->new( clock => sub { '2026-08-12T09:00:00Z' } );
my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Loaded', dir => $root, members => [ 'ada', 'grace', 'alan', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'LDS', epic_prefix => 'LDE', ticket_prefix => 'LDT',
);
$tira->policy_add( project => $root, rule => 'wip-limit',
    column => 'implement', max => 2, action => 'bridge-reminder' );

my %ref;
for my $who (qw(ada grace alan)) {
    my $card = $tira->create_record( project => $root, type => 'ticket', title => "For $who" );
    $tira->record_update( project => $root, ref => $card->{ref}, assignee => $who );
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );
    $ref{$who} = $card->{ref};
}

sub fired {
    my ($found) = grep { $_->{rule} eq 'wip-limit' }
      @{ $tira->policy_evaluate( project => $root ) };
    return $found;
}

# --- it counts the board, which is the useful meaning ---------------------

# One agent per ticket makes a per-agent limit always one, which measures
# nothing. Counting the board measures how much is in flight at once, which is
# a real thing to bound - and three agents doing one card each is exactly the
# behaviour you want, so the message has to let somebody see that at a glance.
my $found = fired();
ok( $found, 'three cards against a limit of two is reported' );
like( $found->{detail}, qr/\b3\b/, 'saying how many there are' );
like( $found->{detail}, qr/limit is 2/, 'and what the limit is' );

# --- and who is holding them ----------------------------------------------

# Without this the message reads the same whether three agents have one card
# each or one agent has three, and those are opposite situations: the first is
# the board working, the second is somebody who should finish something.
like( $found->{detail}, qr/\Q$ref{ada}\E \(ada\)/, 'naming who holds each card' );
like( $found->{detail}, qr/\Q$ref{grace}\E \(grace\)/, 'for every one of them' );
like( $found->{detail}, qr/\Q$ref{alan}\E \(alan\)/, 'so three agents doing one thing each is visible as that' );

# --- a card nobody is carrying --------------------------------------------

{
    my $loose = $tira->create_record( project => $root, type => 'ticket', title => 'Carried by nobody' );
    $tira->record_move(author => 'claude',  project => $root, ref => $loose->{ref}, column => 'implement' );
    like( fired()->{detail}, qr/\Q$loose->{ref}\E \(nobody\)/,
        'and a card nobody is carrying says so rather than looking like somebody has it' );
}

done_testing;

__END__

=head1 NAME

104-wip-limit-across-agents.t - what a work-in-progress limit counts, and who is holding it

=head1 DESCRIPTION

One agent per ticket makes a per-agent limit always one, which measures
nothing. Counting the board measures how much is in flight at once, which is a
real thing to bound - and that was already what the rule did.

What it did not do was say who was holding the cards. The message read exactly
the same whether three agents had one card each or one agent had three, and
those are opposite situations: the first is the board working as intended, the
second is somebody who should finish something before starting another. A rule
whose message cannot tell them apart gets its limit raised until it never
fires, which is the same as deleting it.

=cut
