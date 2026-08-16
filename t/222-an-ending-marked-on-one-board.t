#!/usr/bin/env perl
# A column marked as an ending is an ending, whichever board it was marked on.
#
# column-unwatched describes itself as "a column work happens in that no
# column-scoped policy names", and it was naming columns marked terminal.
# Reported from another project on 2.07, three at once: admin-done,
# done-not-released and release-to-pause, all marked with --terminal, none of
# them a column where work happens.
#
# The rule does check. What it gets wrong is arithmetic across the three
# boards. A board has its own columns per type, and the rule works out the
# endings for each type separately and then merges the working columns of all
# three into one set keyed by name. So a column called shipped that is terminal
# for tickets and not for epics is an ending and a working column at once, and
# the merge keeps the second answer.
#
# Reproduced before this was written, in eight lines: mark shipped terminal for
# tickets only, declare one column-scoped policy, and the rule reports "no
# policy scoped by column watches done, shipped".
#
# The card said the rule did not skip terminal columns. It does. Running it is
# what showed the difference, and the difference is the whole fix.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $store = File::Spec->catdir( $tmp, 'store' );

my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Endings', dir => $root, members => ['claude'],
    columns => ['backlog, implement, review, shipped, done'],
    sow_prefix => 'EDS', epic_prefix => 'EDE', ticket_prefix => 'EDT',
);

# Marked on the board it is an ending for, which is how a board marks one:
# tira.column.update takes a type, so an ending is declared per board.
$tira->column_update( project => $root, type => 'ticket', name => 'shipped', terminal => 1 );

# The rule only speaks when some policy is scoped by column - its point is that
# such a policy stops covering the board the moment a column is added.
$tira->policy_add( project => $root, rule => 'column-unwatched', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'card-duration',
    column => 'implement', age => '4h', action => 'bridge-reminder' );

my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
my @said = map { $_->{detail} // '' }
  grep { ( $_->{rule} // '' ) eq 'column-unwatched' } @{ $pass->{violations} };

# non-empty is the whole claim: a precondition for the two below, which would
# both pass against a rule that said nothing at all.
ok( scalar @said, 'the rule still speaks about columns nobody is watching' );

unlike( join( ' ', @said ), qr/\bshipped\b/,
    'and does not name a column marked as an ending on the board it belongs to' );
# review, which is a column work happens in that no column-scoped policy
# names. Not backlog, which is protected, and not done: with the endings taken
# across every board, a board that has marked none for its epics and SOWs makes
# done an ending there, and an ending anywhere is an ending everywhere. The
# first version of this expected done and was measuring the old arithmetic.
like( join( ' ', @said ), qr/\breview\b/,
    'while a column nobody marked and nobody watches is still named' );

done_testing;

__END__

=head1 NAME

222-an-ending-marked-on-one-board.t - an ending is an ending on every board

=head1 DESCRIPTION

C<column-unwatched> excludes terminal columns, and worked out the endings for
each board type separately while merging the working columns of all three by
name. A column terminal for tickets and not for epics was therefore both, and
the merge kept the wrong answer - which is how a board that had marked three
endings was told about all three.

=cut
