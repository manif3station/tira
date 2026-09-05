#!/usr/bin/env perl
# TKT-595. The card dialog's Linkage section shows Epic Ref, Parent Ticket
# Ref, Sub Ticket Refs and typed links, but not the tasklist items that
# reference the card. Owner, with a screenshot of that section: "also show
# linked tasks".
#
# THE CLI HALF ALREADY SHIPPED, independently, as TKT-802:
# `tasklist_list(ref => REF, all_sessions => 1)` already answers "which
# tasks point at this card". Confirmed live in a container before writing
# this file. Nothing here re-proves that - it is not this ticket's gap.
#
# THE GAP IS THE BROWSER'S OWN PROVIDER AND THE DIALOG. `GET /tasklist`
# already exists and already reaches `tasklist_list`, but its provider
# forwarded only `session` - never `ref` or `all_sessions` - so the same
# filter the CLI has had since TKT-802 was unreachable from the page the
# owner was looking at. And nothing in the dialog's own Linkage-building code
# ever called it.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite;
use Tira;

require Tira::CLI::Browser;

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

my $tira = Tira->new( clock => sub {'2026-09-05T09:00:00Z'} );
$tira->project_new(
    name => 'Linked', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'LKS', epic_prefix => 'LKE', ticket_prefix => 'LKT',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'A card with tasks' );
my $task = $tira->tasklist_add(
    project => $root, author => 'claude', text => 'do the thing', session => 'sessA' );
$tira->tasklist_task_ref_link(
    project => $root, author => 'claude', session => 'sessA', id => $task->{id}, refs => [ $card->{ref} ] );

# A second session's task, pointed at the same card - what session=>1
# has to reach, since a signed-in human dashboard view is not one agent's
# own queue. Confirmed on TKT-595's own key_details: "all sessions with the
# owning session named beside each task".
my $other_task = $tira->tasklist_add(
    project => $root, author => 'claude', text => 'a different session saw this too', session => 'sessB' );
$tira->tasklist_task_ref_link(
    project => $root, author => 'claude', session => 'sessB', id => $other_task->{id}, refs => [ $card->{ref} ] );

# --- SERVER: the provider passes ref/all_sessions through, not just session -

my %provider = Tira::CLI::Browser::providers( tira => $tira, project => $root );
ok( ref $provider{tasklist} eq 'CODE', 'the page has a provider it reads the tasklist through' );

my $decode = Tira::json_object();

{
    # session left as the caller's own, deliberately empty here - a caller
    # with no session id must not silently see every session's tasks by
    # having --ref alone override the existing scoping.
    my $json = $provider{tasklist}->( { ref => $card->{ref} } );
    my $items = $decode->decode($json);
    is( scalar @{$items}, 0,
        '--ref alone, with no --all-sessions, still respects normal session scoping '
          . '- confirmed empty because neither task was written under the caller\'s own (blank) session' );
}

{
    my $json = $provider{tasklist}->( { ref => $card->{ref}, all_sessions => 1 } );
    my $items = $decode->decode($json);
    is( scalar @{$items}, 2, 'ref + all_sessions finds both tasks that point at the card' );
    my %by_id = map { $_->{id} => $_ } @{$items};
    ok( $by_id{ $task->{id} }, 'the first session\'s task is there' );
    ok( $by_id{ $other_task->{id} }, 'and the second session\'s' );
    is( $by_id{ $other_task->{id} }{session}, 'sessB',
        'each carries which session it belongs to, so the owning session can be shown beside it' );
}

{
    my $unrelated = $tira->create_record( project => $root, type => 'ticket', title => 'Nothing points here' );
    my $json = $provider{tasklist}->( { ref => $unrelated->{ref}, all_sessions => 1 } );
    my $items = $decode->decode($json);
    is( scalar @{$items}, 0, 'a card nothing points at gets an empty list, not every task' );
}

# --- CLIENT: the dialog actually asks, and renders read-only rows -----------

my $js = Suite::view_source('live-helpers.js');

like( $js, qr{/tasklist\?ref=}, 'the dialog fetches the tasklist scoped to the card it is showing' );
like( $js, qr{all_sessions=1}, 'and asks for every session, not just its own' );

# The fetch has to land inside the SAME code path that builds the rest of
# Linkage, close to where it is appended - not a second, independent section
# elsewhere in the file that could silently drift from where Linkage itself
# renders or fails to render (a card with no `record.linkage` at all). The
# whole file is one minified line, so "close to" is asserted by proximity
# within the source rather than by a line boundary neither original code nor
# this fix has.
like( $js, qr{/tasklist\?ref=.{0,1200}?sectionsHost\.appendChild\(section\("Linkage",box\)\)},
    'the tasklist fetch sits just before the Linkage section is appended, '
      . 'inside the same code path rather than a second, independent one' );

done_testing();

__END__

=head1 NAME

557-a-card-dialog-blind-to-its-own-tasks.t - the card dialog can see the tasks that point at it

=head1 DESCRIPTION

TKT-595. The card dialog's Linkage section showed every relation a card can
have except the tasklist items that name it - the reporter's own words,
with a screenshot. The CLI half of the reverse lookup already shipped as
TKT-802 (C<tasklist_list --ref REF --all-sessions>); the gap was the
browser's own C<GET /tasklist> provider, which forwarded only C<session>,
and the dialog itself, which never asked.

C<Tira::CLI::Browser>'s C<tasklist> provider now passes C<ref> and
C<all_sessions> through when the query carries them, and
C<lib/Tira/views/live-helpers.js> fetches C<< /tasklist?ref=...&all_sessions=1 >>
inside the same code that builds the rest of the Linkage section, rendering
each task's id, text, status and owning session.

=cut
