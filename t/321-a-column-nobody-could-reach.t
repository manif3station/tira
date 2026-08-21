#!/usr/bin/env perl
# column_add lets a new column be inserted --after or --before an existing
# one, but that only affects display/derived order - it does not touch the
# neighbor's own explicit --next, if that neighbor already has one. A column
# whose next was set before the insertion keeps pointing past the new
# column, which becomes structurally present but unreachable by the chain
# check.
#
# Self-inflicted and reported through tira.dev.found: a 'Rebuild Container'
# column added --after final-check, where final-check's own --next already
# read ['release-held','done'] from before the column existed. Since that
# next was explicit rather than derived from position, the chain check let a
# card go straight from final-check to release-held, silently skipping the
# new column. TKT-456.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Chained', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'final-check', 'release-held', 'done' ],
    sow_prefix => 'CHS', epic_prefix => 'CHE', ticket_prefix => 'CHT',
);

# The setup this bug needs: final-check's own next made explicit, matching
# what it already was by position, before the new column exists at all.
$tira->column_update(
    project => $root, type => 'ticket', name => 'final-check',
    next => [ 'release-held', 'done' ],
);

is_deeply( $tira->warning_list( project => $root ), [],
    'nothing has gone wrong yet' );

# Inserted between final-check and release-held - exactly where the owner
# put it, and exactly where final-check's explicit next does not look.
$tira->column_add(
    project => $root, type => 'ticket', name => 'rebuild-container',
    after => 'final-check',
);

my $warnings = $tira->warning_list( project => $root );
is( scalar @{$warnings}, 1, 'inserting an unreachable column leaves a warning' );
like( $warnings->[0]{message}, qr/rebuild-container/,
    'naming the column that cannot be reached' );
like( $warnings->[0]{message}, qr/final-check/,
    'and the neighbor whose chain does not reach it' );
like( $warnings->[0]{message}, qr/tira\.column\.update/,
    'and how to fix it' );

# The column is still created - this is advisory, not a refusal.
my $columns = $tira->column_list( project => $root, type => 'ticket' );
ok( ( grep { $_->{name} eq 'rebuild-container' } @{$columns} ),
    'the column exists regardless of the warning' );

# --- the quiet cases: nothing wrong, nothing said ---------------------------

{
    my $other = File::Spec->catdir( $tmp, 'unchained' );
    $tira->project_new(
        name => 'Unchained', dir => $other, members => ['claude'],
        columns => [ 'backlog', 'planning', 'doing', 'done' ],
        sow_prefix => 'UCS', epic_prefix => 'UCE', ticket_prefix => 'UCT',
    );

    # No column here has an explicit next at all - everything is still
    # derived from position, so there is nothing an insertion could break.
    $tira->column_add(
        project => $other, type => 'ticket', name => 'review',
        after => 'planning',
    );
    is_deeply( $tira->warning_list( project => $other ), [],
        'inserting where nothing is explicit says nothing' );

    # An explicit next that already names the new column - the owner wired
    # it correctly, or the chain simply passes through unaffected.
    $tira->column_update(
        project => $other, type => 'ticket', name => 'doing',
        next => [ 'review', 'done' ],
    );
    $tira->column_add(
        project => $other, type => 'ticket', name => 'triage',
        before => 'planning',
    );
    is_deeply( $tira->warning_list( project => $other ), [],
        'an insertion nowhere near an explicit chain says nothing' );

    # Appending at the very end - no earlier neighbor to check at all.
    $tira->column_add( project => $other, type => 'ticket', name => 'archived', after => 'done' );
    is_deeply( $tira->warning_list( project => $other ), [],
        'appended past the last column, there is no neighbor to break' );
}

done_testing;

__END__

=head1 NAME

321-a-column-nobody-could-reach.t - inserting a column can strand it behind an explicit chain

=head1 DESCRIPTION

C<column_add> positions a new column with C<--after>/C<--before>, but that is
purely a display/derived-order operation - it never touches a neighboring
column's own explicit C<next>. When that neighbor's next was already set
before the insertion, the new column is structurally present but
unreachable: the chain check keeps deriving nothing new from position,
because there is nothing left to derive.

Advisory, not a refusal - the column is still created, and a warning is
left where C<tira.warning.list> (the same channel a failed reminder
delivery uses) will show it, naming the unreachable column, its neighbor,
and the command that wires the chain correctly.

=cut
