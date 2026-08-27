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

# TKT-537: a tasklist item's --session privacy (TKT-505) is not privacy at
# all if a search from a different session can still surface it.
my $private_a = $tira->tasklist_add( project => $root, text => 'agent-a private laundry list', session => 'agent-a' );
my $private_b = $tira->tasklist_add( project => $root, text => 'agent-b private laundry list', session => 'agent-b' );

is_deeply(
    $tira->search( project => $root, text => 'private laundry', tasklist => 1, refs_only => 1, session => 'agent-a' ),
    [ $private_a->{id} ],
    'searching under session agent-a only finds agent-a\'s own tasklist item, not agent-b\'s' );

is_deeply(
    $tira->search( project => $root, text => 'private laundry', tasklist => 1, refs_only => 1, session => 'agent-b' ),
    [ $private_b->{id} ],
    'and searching under session agent-b only finds agent-b\'s own item' );

# --- TKT-550: the supervisor's opt-in, and what it must not cost -------------
#
# TKT-539 gave tasklist.list --all-sessions so a supervising agent could see
# several subagents' lists without already knowing each session id. search
# --tasklist never got the equivalent, so the same supervisor could not find
# an item by text across sessions at all.
#
# The filter it has to cross is the privacy boundary asserted directly above,
# not an oversight - so this is a strict opt-in, exactly the shape TKT-539
# used: absent, nothing changes. The two assertions above are the ones that
# must keep passing untouched, and they do.

is_deeply(
    [ sort @{ $tira->search(
        project => $root, text => 'private laundry', tasklist => 1,
        refs_only => 1, session => 'agent-a', all_sessions => 1 ) } ],
    [ sort ( $private_a->{id}, $private_b->{id} ) ],
    '--all-sessions reaches every session\'s tasklist items, not just the caller\'s' );

# A flat list of ids and text with no way to tell whose they are would
# reproduce the gap TKT-539 closed rather than close it here: the supervisor's
# next question is always "whose is this". tasklist.list --all-sessions
# answers it by keeping each item's own session field, and a search hit has to
# do the same.
{
    # search returns { hits => [...], count => N } unless refs_only or count
    # is asked for - the first version of this dereferenced the hashref itself
    # and died rather than failing, which is not a red test.
    my $result = $tira->search(
        project => $root, text => 'private laundry', tasklist => 1,
        session => 'agent-a', all_sessions => 1 );
    my %session_of = map { $_->{ref} => $_->{session} } @{ $result->{hits} };
    is( $session_of{ $private_a->{id} }, 'agent-a', 'a cross-session hit names the session it came from' );
    is( $session_of{ $private_b->{id} }, 'agent-b', 'including the one the caller does not own' );
}

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
