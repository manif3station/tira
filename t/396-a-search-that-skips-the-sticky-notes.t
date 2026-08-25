#!/usr/bin/env perl
# TKT-533: tira.search only ever walked the sow/epic/ticket boards
# (record_list) - a tasklist item, stored separately (.tira/tasklist.json),
# was invisible to it no matter how distinctive its text. Opting in with
# --tasklist now also matches a tasklist item's text/id/refs, without
# changing default search behavior for a caller that never asks for it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-25T22:00:00+0100' } );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Findable Tasks', dir => $root, columns => ['Backlog, Doing'],
    sow_prefix => 'FTS', epic_prefix => 'FTE', ticket_prefix => 'FTT',
);
my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Unrelated ticket' );
my $task = $tira->tasklist_add( project => $root, text => 'Reticulate the splines before Thursday' );
my $other = $tira->tasklist_add( project => $root, text => 'Something else entirely' );
$tira->tasklist_task_ref_link( project => $root, id => $task->{id}, refs => ['FTT-1'] );

is_deeply(
    $tira->search( project => $root, text => 'reticulate', refs_only => 1 ),
    [], 'without --tasklist, a search matching only tasklist text finds nothing - unchanged default behavior' );

is_deeply(
    $tira->search( project => $root, text => 'reticulate', tasklist => 1, refs_only => 1 ),
    [ $task->{id} ], 'with --tasklist, a search matching the item text finds it by id' );

is_deeply(
    $tira->search( project => $root, text => $task->{id}, tasklist => 1, refs_only => 1 ),
    [ $task->{id} ], 'a tasklist item is also findable by its own id' );

is_deeply(
    $tira->search( project => $root, text => 'ftt-1', tasklist => 1, refs_only => 1 ),
    [ $task->{id} ], 'and by a ref linked to it, case-insensitively' );

is_deeply(
    [ sort @{ $tira->search( project => $root, text => 'Unrelated', tasklist => 1, refs_only => 1 ) } ],
    [ $ticket->{ref} ], 'existing sow/epic/ticket matches are unaffected by --tasklist' );

done_testing;

__END__

=head1 NAME

396-a-search-that-skips-the-sticky-notes.t - tira.search --tasklist also matches tasklist items

=head1 DESCRIPTION

TKT-533: search() (lib/Tira.pm) called record_list, which walks only the
sow/epic/ticket boards - a tasklist item, stored separately, was invisible
to it regardless of how distinctive its text was. This proves the new
--tasklist opt-in matches a tasklist item's text, id, and linked refs
without changing default search behavior for a caller that never asks for
it, and that ordinary record hits keep working the same with --tasklist on.

=cut
