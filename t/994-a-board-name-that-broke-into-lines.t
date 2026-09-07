#!/usr/bin/env perl
# TKT-994. Found by the hourly hunt immediately after shipping TKT-981.
#
# _bridge_line composes "board: $violation->{board}" verbatim at the end of
# a composed line, where the board name comes straight from a project's own
# name (project_new --name, unvalidated against newlines) - a field TKT-981
# never touched, since that fix only reached the detail field. A project
# name containing newlines breaks the one-violation-per-line contract
# exactly the same way TKT-981's job message did.
#
# THE STORED PROJECT NAME MUST STAY EXACTLY AS WRITTEN, same reasoning as
# TKT-981: this is a rendering fix, not a storage one.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $tira  = Tira->new( clock => sub {'2026-09-07T21:00:00Z'} );
my $store = File::Spec->catdir( $tmp, 'store' );

my $multiline_name = "First line of the name.\nSecond line, after a newline.";

# --- the composed bridge line is exactly one line, board name included ------

{
    $tira->bridge_write( store => $store, violations => [
        { id => 'VIO-0000', ref => 'TKT-000', rule => 'card-stalled',
            detail => 'seed', action => 'bridge-reminder', tone => 'note' } ] );
    my $before = scalar @{ $tira->bridge_backlog( store => $store, lines => 1000 ) };

    my $written = $tira->bridge_write(
        store => $store,
        violations => [
            { id => 'VIO-0001', ref => 'TKT-001', rule => 'card-stalled',
                detail => 'ordinary detail', action => 'bridge-reminder', tone => 'note',
                board => $multiline_name },
        ],
    );
    is( $written, 1, 'the violation is written' );

    my $backlog = $tira->bridge_backlog( store => $store, lines => 1000 );
    my $after = scalar @{$backlog};
    is( $after - $before, 1,
        'one violation, however many lines its board name spans, costs the backlog exactly one line' )
      or diag( 'backlog now: ' . join( "\n---\n", @{$backlog} ) );

    my @entries = grep { /VIO-0001/ } @{$backlog};
    is( scalar @entries, 1, 'and its own id-bearing line is findable' );
    like( $entries[0] // '', qr/board: First line of the name\. Second line, after a newline\./,
        'the board name survives, whitespace-collapsed rather than dropped' );
}

# --- the stored project name is untouched -----------------------------------

{
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => $multiline_name, dir => $root, columns => ['backlog, done'],
        members => ['claude'], sow_prefix => 'MLS', epic_prefix => 'MLE', ticket_prefix => 'MLT',
    );
    is( $tira->project_show( project => $root )->{name}, $multiline_name,
        'the stored project name keeps its own newlines exactly as written - this is a rendering fix, not a storage one' );
}

# --- an ordinary single-line board name is unchanged ------------------------

{
    my $store2 = File::Spec->catdir( $tmp, 'store2' );
    $tira->bridge_write( store => $store2, violations => [
        { id => 'VIO-0002', ref => 'TKT-002', rule => 'card-stalled',
            detail => 'ordinary', action => 'bridge-reminder', tone => 'note',
            board => 'A Perfectly Normal Board' },
    ] );
    my @entries = grep { /VIO-0002/ } @{ $tira->bridge_backlog( store => $store2, lines => 1000 ) };
    like( $entries[0] // '', qr/board: A Perfectly Normal Board\z/,
        'a single-line board name is composed exactly as before' );
}

done_testing();

__END__

=head1 NAME

994-a-board-name-that-broke-into-lines.t - the bridge's board field survives a
multi-line project name

=head1 DESCRIPTION

TKT-994. C<_bridge_line>'s C<board: $name> segment interpolated a project's
own name verbatim - a project name containing newlines broke the bridge's
one-violation-per-line contract exactly the way TKT-981's job message did,
in a field that fix never reached. The board name is now collapsed the same
way the detail field already is: whitespace runs folded to a single space,
trimmed at both ends. The stored project name is untouched; only the
composed bridge line is affected.

=cut
