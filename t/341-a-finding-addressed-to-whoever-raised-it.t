#!/usr/bin/env perl
# checklist-unmoved's finding was addressed to the card's ASSIGNEE - correct
# for most rules, but for a card sitting in review, the assignee is often
# the reviewer, who cannot tick a checklist item only the card's author
# left unticked. Michael's own answer to the question this rule shipped
# with (Q-064, TKT-286): address it to the reporter instead, who raised the
# card and is who a checklist item usually belongs to.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $step = 0;
my @times = map { sprintf '2026-08-23T10:%02d:00Z', $_ } 0 .. 59;
my $tira = Tira->new( clock => sub { $times[ $step++ ] // $times[-1] } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Addressed', dir => $root, members => [ 'ada', 'grace' ],
    columns => ['backlog, tests-red, implement, done'],
    sow_prefix => 'ADS', epic_prefix => 'ADE', ticket_prefix => 'ADT',
);
$tira->policy_add( project => $root, rule => 'checklist-unmoved', action => 'bridge-reminder' );

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'Reviewed by somebody else',
    reporter => 'ada', assignee => 'grace' );
$tira->checklist_add( author => 'ada',
    project => $root, ref => $card->{ref}, item => 'do the work', status => 'todo' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'tests-red', author => 'ada' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'grace' );

my $store = File::Spec->catdir( $tmp, 'store' );
my $pass  = $tira->police_pass( project => $root, store => $store, world => {} );
my ($found) = grep { ( $_->{rule} // '' ) eq 'checklist-unmoved' } @{ $pass->{violations} };

ok( $found, 'the move with nothing ticked is still reported' );
is( $found->{assignee}, 'ada', 'addressed to the reporter, ada, not the assignee grace' );
isnt( $found->{assignee}, $card->{assignee}, 'and specifically not the card assignee, who may be a reviewer who cannot act on it' );

done_testing;

__END__

=head1 NAME

341-a-finding-addressed-to-whoever-raised-it.t - checklist-unmoved addresses the reporter

=head1 DESCRIPTION

C<checklist-unmoved>'s finding was addressed to the card's ASSIGNEE, who
may be the reviewer for a card sitting in review - somebody who cannot
tick a checklist item only the card's author left unticked. Addressed to
the reporter instead, per Michael's own answer to the question this rule
shipped with unresolved (Q-064, TKT-286).

=cut
