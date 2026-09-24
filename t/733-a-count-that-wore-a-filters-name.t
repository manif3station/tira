#!/usr/bin/env perl
# TKT-733. ticket.list --label VALUE is accepted by the shared option
# spec ('label=s@') but record_list's per-record filter block never
# reads $args{labels} at all - the unfiltered board comes back regardless
# of the label given, including a label that matches nothing. A
# nonsense label proves it: no card could possibly match, and every
# card comes back anyway.
#
# WRITTEN RED: record_list has no labels filter yet, so this reproduces
# against the pre-fix code.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-09-24T22:00:00Z'} );
$tira->project_new(
    name => 'A count that wore a filters name', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'PLW', epic_prefix => 'PLE', ticket_prefix => 'PLT',
);

my $with_label = $tira->create_record(
    project => $root, type => 'ticket', title => 'Has the label', labels => ['Hourly Bugfix'] );
my $without_label = $tira->create_record(
    project => $root, type => 'ticket', title => 'No label at all' );

my $all = $tira->record_list( project => $root, type => 'ticket' );
is( scalar @{$all}, 2, 'control: both cards exist, unfiltered' );

my $filtered = $tira->record_list( project => $root, type => 'ticket', labels => ['Hourly Bugfix'] );
is( scalar @{$filtered}, 1, '--label narrows to only the matching card, not the whole board' );
is( $filtered->[0]{ref}, $with_label->{ref}, 'and it is the RIGHT card' )
  if @{$filtered} == 1;

my $nonsense = $tira->record_list( project => $root, type => 'ticket', labels => ['nonsense-label-xyz'] );
is( scalar @{$nonsense}, 0, 'a label matching nothing returns nothing, not the whole board' );

# OR semantics: matching ANY of several given labels, the conventional
# meaning for a repeatable filter flag.
my $second_label = $tira->create_record(
    project => $root, type => 'ticket', title => 'Has the other label', labels => ['Routine Doc Check'] );
my $either = $tira->record_list(
    project => $root, type => 'ticket', labels => [ 'Hourly Bugfix', 'Routine Doc Check' ] );
is( scalar @{$either}, 2, '--label given twice matches ANY of the values (OR), not requiring all of them' );

done_testing();

__END__

=head1 NAME

733-a-count-that-wore-a-filters-name.t - record_list actually filters by
--label instead of silently returning the whole board

=head1 DESCRIPTION

TKT-733. C<--label> was accepted at the option-parsing layer
(C<label=s@>) but C<record_list>'s per-record filter block never read
C<$args{labels}> - every call, matching or not, returned the entire
board. A nonsense label proved it: nothing could match, and the full
count came back anyway, which fails OPEN (a large, plausible number)
rather than closed (an obvious zero) - the more dangerous failure
direction, because the wrong answer looks right. C<record_list> now
filters on C<$args{labels}> with OR semantics (a record matches if it
carries ANY of the given values), matching how C<--label> is already
repeatable at the option layer.

=cut
