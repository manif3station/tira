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
#
# Codex review: a first draft compared raw strings, so a stored
# 'Hourly Bugfix' never matched --label 'hourly bugfix' even though
# labels are documented and stored case-insensitively - fixed by
# case-folding both sides. Also added: --refs-only coverage (the fast
# path this fix also had to exclude --label from), --count coverage
# (the exact shape the original report measured), and a real CLI
# dispatch pass, not just record_list called directly.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

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

# --- case-insensitive, matching how labels are already stored ------------

my $case_mismatched = $tira->record_list( project => $root, type => 'ticket', labels => ['hourly bugfix'] );
is( scalar @{$case_mismatched}, 1, 'a differently-cased --label value still matches, same as labels are stored case-insensitively' );

# OR semantics: matching ANY of several given labels, the conventional
# meaning for a repeatable filter flag.
my $second_label = $tira->create_record(
    project => $root, type => 'ticket', title => 'Has the other label', labels => ['Routine Doc Check'] );
my $either = $tira->record_list(
    project => $root, type => 'ticket', labels => [ 'Hourly Bugfix', 'Routine Doc Check' ] );
is( scalar @{$either}, 2, '--label given twice matches ANY of the values (OR), not requiring all of them' );

# --- --count composes with --label, the exact shape the original report --
# --- measured (277 back for every label tried) ----------------------------

my $counted = $tira->record_list( project => $root, type => 'ticket', labels => ['Hourly Bugfix'], count => 1 );
is_deeply( $counted, { count => 1 }, '--count composes with --label, answering the filtered count, not the board total' );
my $counted_nonsense = $tira->record_list( project => $root, type => 'ticket', labels => ['nonsense-label-xyz'], count => 1 );
is_deeply( $counted_nonsense, { count => 0 }, 'and a nonsense label + --count answers zero, not the board total' );

# --- --refs-only + --label is not answered from the filename-only fast ---
# --- path, which cannot see labels at all ---------------------------------

my $refs = $tira->record_list( project => $root, type => 'ticket', labels => ['Hourly Bugfix'], refs_only => 1 );
is_deeply( $refs, [ $with_label->{ref} ], '--refs-only + --label is filtered too, not answered from the fast filename-only path' );

# --- exercised through the real CLI dispatch, not just record_list directly

sub run_cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => 'record.list', type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

my ( $status, $out, $err ) = run_cli( '--label', 'Hourly Bugfix', '--count', '-o', 'json' );
is( $status, 0, 'ticket.list --label --count runs cleanly through the real CLI dispatch' );
is( $out, qq({"count":1}\n), 'and answers the filtered count, not the board total' );

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
carries ANY of the given values) - the chosen semantics for this fix,
not something C<--label>'s repeatable option declaration dictates by
itself. Comparison is case-folded on both sides, matching how labels
are already stored case-insensitively. C<--refs-only> (a fast,
filename-only path that cannot see labels at all) and C<--count> both
compose correctly with the new filter.

=cut
