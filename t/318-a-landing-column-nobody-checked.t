#!/usr/bin/env perl
# The backward-reset range stopped one column short of where the card
# actually landed.
#
# _apply_column_required_actions's backward branch reset every required
# item tagged with a column strictly between the new position (exclusive)
# and the old one (inclusive) - deliberately, t/309 tested exactly this
# exclusion. The owner's report (TG msg 4342): moving a card from column 4
# to column 2 should reset required items for columns 4, 3 AND 2 - the
# column the card is actually landing on, not just what it passed through
# on the way. Currently only 4 and 3 reset; 2's own item, if already marked
# done from an earlier pass through, stays done - so re-entering a column
# does not mean its own check has to be satisfied again, which is the
# opposite of what redoing that work is supposed to require.

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
my $tira = Tira->new;
$tira->project_new(
    name => 'Landing', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'doc', 'code', 'review' ],
    sow_prefix => 'LDS', epic_prefix => 'LDE', ticket_prefix => 'LDT',
);
$tira->column_update( project => $root, type => 'ticket', name => 'planning', required_action => ['left a note'] );
$tira->column_update( project => $root, type => 'ticket', name => 'doc', required_action => ['reviewed'] );
$tira->column_update( project => $root, type => 'ticket', name => 'code', required_action => ['tests green'] );

sub cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    return Tira::CLI->run( command => 'record.move', type => 'ticket', argv => \@argv );
}

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Round trip' );

sub status_of {
    my ($item_name) = @_;
    my ($item) = grep { $_->{item} eq $item_name }
      @{ $tira->required_item_list( project => $root, ref => $card->{ref} ) };
    return $item->{status};
}

sub mark_done {
    my ($item_name) = @_;
    my ($item) = grep { $_->{item} eq $item_name }
      @{ $tira->required_item_list( project => $root, ref => $card->{ref} ) };
    $tira->required_item_update( project => $root, ref => $card->{ref}, id => $item->{id},
        status => 'done', command => ['did it'], proof => ['done'] );
}

# Walk forward through planning, doc, code (index 1, 2, 3) - each column's
# required item has to be marked done before the move-out gate allows
# leaving it, so marking and moving interleave.
cli( '--ref', $card->{ref}, '--column', 'planning' );
mark_done('left a note');
cli( '--ref', $card->{ref}, '--column', 'doc' );
mark_done('reviewed');
cli( '--ref', $card->{ref}, '--column', 'code' );

is( status_of('left a note'), 'done', 'planning item is done before the backward move' );
is( status_of('reviewed'), 'done', 'doc item is done before the backward move' );

# Move backward from code (index 3) to planning (index 1) - two columns
# back. planning is the DESTINATION: it should reset too, not just doc
# (the column strictly passed through).
cli( '--ref', $card->{ref}, '--column', 'planning' );

is( status_of('left a note'), 'pending',
    "the destination column's own required item resets too, not just the ones passed through" );
is( status_of('reviewed'), 'pending', 'and the column actually passed through still resets, as before' );

done_testing;

__END__

=head1 NAME

318-a-landing-column-nobody-checked.t - a backward move resets the destination column's required items too

=head1 DESCRIPTION

Before this fix, C<_apply_column_required_actions>'s backward branch reset
required items strictly between the new position and the old one,
excluding the destination itself - deliberately, per t/309. The owner
asked for the destination to reset too: landing back on a column should
mean that column's own checks need satisfying again, the same as any
column merely passed through. TKT-455.

=cut
