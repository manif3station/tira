#!/usr/bin/env perl
# Creation seeds a birth entry for every FIELD a create call populates, but
# not for the STARTING COLUMN - column is deliberately not a stored field,
# it is the directory the record file sits in, so the generic per-field
# journaling (_journal_changes) never sees it. record_move seeds column
# history manually, via its own direct _journal_record call; create_record
# has no equivalent, so a card created directly into a non-default column
# has no history entry recording it ever arrived there. column-skipped reads
# exactly that history to decide whether a column was visited, and flags the
# card as having skipped every column up to and including the one it was
# actually created in - it genuinely was there the whole time.
#
# Reported from mt5-ai (TG bridge), verified live on our own board: five
# cards across one session, each needing a full walk-through of every
# required column purely to generate the missing history entries a stranger
# reading the board would reasonably assume already existed.

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
    name => 'Arrived', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'in-progress', 'done' ],
    sow_prefix => 'ARS', epic_prefix => 'ARE', ticket_prefix => 'ART',
);

# --- a card created into the default column gets a birth entry for it -----
my $default_card = $tira->create_record( project => $root, type => 'ticket', title => 'Default column' );
my $default_history = $tira->history_list( project => $root, ref => $default_card->{ref}, field => 'column' );
is( scalar @{$default_history}, 1, 'one column history entry exists the moment the card is created' );
is( $default_history->[0]{op}, 'create', 'tagged as a creation, not a move' );
is( $default_history->[0]{before}, undef, 'nothing before it - this is where it started' );
is( $default_history->[0]{after}, 'backlog', 'naming the column it actually landed in' );

# --- a card created directly into an explicit, non-default column ---------
my $explicit_card = $tira->create_record(
    project => $root, type => 'ticket', title => 'Explicit column', column => 'planning' );
my $explicit_history = $tira->history_list( project => $root, ref => $explicit_card->{ref}, field => 'column' );
is( scalar @{$explicit_history}, 1, 'the explicit --column also gets a birth entry' );
is( $explicit_history->[0]{op}, 'create', 'tagged as a creation' );
is( $explicit_history->[0]{after}, 'planning', 'naming the column actually given, not the board default' );

# --- a real move afterward still journals normally, distinguishable -------
$tira->record_move(author => 'claude',  project => $root, type => 'ticket', ref => $explicit_card->{ref}, column => 'in-progress' );
my $after_move = $tira->history_list( project => $root, ref => $explicit_card->{ref}, field => 'column' );
is( scalar @{$after_move}, 2, 'the real move adds a second entry on top of the birth one' );
is( $after_move->[1]{op}, 'move', 'the move is tagged move, not create - the two stay distinguishable' );
is( $after_move->[1]{before}, 'planning', 'and it correctly picks up from where the card actually was' );

done_testing;

__END__

=head1 NAME

301-a-card-that-arrived-from-nowhere.t - creation seeds a birth entry for the starting column, not just for fields

=head1 DESCRIPTION

Covers TKT-433: create_record now writes a manual history entry for the
column a card starts in (op => 'create', field => 'column', before =>
undef, after => the starting column), mirroring record_move's own existing
direct _journal_record call for column changes rather than the generic
per-field mechanism, which never sees column at all since it is not a
stored record field. Applies whether the card lands in the board's default
entry column or an explicit --column. A subsequent real move still journals
normally, tagged 'move' rather than 'create', so the two remain
distinguishable to anything reading history - including column-skipped,
which was flagging cards that never actually skipped anything.

=cut
