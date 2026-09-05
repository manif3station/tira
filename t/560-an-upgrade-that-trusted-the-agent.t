#!/usr/bin/env perl
# TKT-604, TSK-181. His own request: "I want the police to raise a ticket to
# gate the upgrade... What have changes will be in the ticket? What new
# commands and what new policies options between old and new version? Set a
# checklist on the ticket the agent to pick up and do."
#
# THE UPGRADE LINE TRUSTED THE AGENT TO ACT ON IT. police_pass already
# detects a genuine version change once (t/246) and hands the bridge an
# "UPGRADE" line naming the version pair - a line among many others, easy to
# scroll past, with nothing tracking whether it was ever acted on. A gating
# ticket is a standing item on the board instead: it does not go away until
# somebody closes it, the way the rest of this pipeline works.
#
# WHAT MUST NOT HAPPEN: a first-ever pass on a board that has never been
# policed announces "Tira is now X" with no "from" - there is nothing to have
# missed, so no ticket. And announced_changes (t/246's own guard) must cover
# the ticket too, or a restarting police files one every time it comes back
# up.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-05T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Gated', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'GAS', epic_prefix => 'GAE', ticket_prefix => 'GAT',
);

# A declared policy, because a board with none is answered with advice about
# declaring some and never reaches the version notice at all (t/246's own
# note on this).
$tira->policy_add( project => $root, rule => 'orphan-card', action => 'log-only' );

my $store = File::Spec->catdir( $tmp, 'police' );

sub tickets_now {
    return @{ $tira->record_list( project => $root, type => 'ticket', include_discard => 1 ) };
}

sub pass_at {
    my ($version) = @_;
    no warnings 'redefine';
    local $Tira::VERSION = $version;
    return $tira->police_pass( project => $root, store => $store, world => {} );
}

# --- the very first pass: nothing to have missed, so no ticket -------------

is( pass_at('9.11')->{upgraded}{to}, '9.11', 'the first-ever pass announces a version' );
is( scalar tickets_now(), 0, 'and raises no gating ticket - there is no "from" to have missed anything in' );

# --- a genuine upgrade raises one -------------------------------------------

my $said = pass_at('9.12');
ok( $said->{upgraded}, 'a genuine upgrade is still announced on the bridge, unchanged' );

my @after_upgrade = tickets_now();
is( scalar @after_upgrade, 1, 'exactly one gating ticket is raised for the upgrade' );

my $gate = $after_upgrade[0];
like( $gate->{title}, qr/9\.11/, "the ticket's title names the version upgraded from" );
like( $gate->{title}, qr/9\.12/, "and the version upgraded to" );
is( $gate->{priority}, 5, 'raised at the most urgent priority - 5 is the top of this board\'s scale' );
is( $gate->{column}, 'backlog', 'landed in the backlog rather than the owner\'s next-to-work-on column' );

like( $gate->{description}, qr/9\.11/, "the description says what changed between the two versions" );

my @items = @{ $gate->{checklist} // [] };
ok( scalar(@items) > 1, 'the checklist carries more than one item - reading commands plus every undeclared rule' );
ok( ( grep { $_->{item} =~ /new commands/i } @items ),
    'one checklist item is to read the new commands' );
ok( ( grep { $_->{item} =~ /orphan-card/ } @items ) == 0,
    'the one rule this board already declared is not listed as something to decide' );
ok( ( grep { $_->{item} =~ /card-full-details/ } @items ),
    'an undeclared rule is listed as something to declare or decline' );

# --- restarting police does not file a second one ---------------------------

is( pass_at('9.12')->{upgraded}, undef, 'the same watcher passing again announces nothing new' );
is( scalar tickets_now(), 1, 'and still exactly one gating ticket - restarting police must not duplicate it' );

# --- nor does a second watcher at the same version --------------------------

is( pass_at('9.12')->{upgraded}, undef, 'a second watcher already at the announced version says nothing either' );
is( scalar tickets_now(), 1, 'still exactly one ticket' );

# --- a board already at the installed version when policing starts ---------

{
    my $fresh_store = File::Spec->catdir( $tmp, 'fresh-police' );
    no warnings 'redefine';
    local $Tira::VERSION = '9.12';
    $tira->police_pass( project => $root, store => $fresh_store, world => {} );
    is( scalar tickets_now(), 1,
        'a board already running the installed version when police starts files no ticket at all' );
}

done_testing();

__END__

=head1 NAME

560-an-upgrade-that-trusted-the-agent.t - police raises a gating ticket on a genuine upgrade instead of a bridge line alone

=head1 DESCRIPTION

TKT-604, TSK-181. C<police_pass> already announces a genuine version change
once (C<t/246>) as a bridge line the agent could scroll past. It now also
raises a ticket in the backlog, at the top of this board's priority scale,
naming the version pair, carrying the Changes entries between them as its
description, and a checklist with one item to read the new commands and one
item per rule this board has not yet declared or declined. The first-ever
pass on an unpoliced board has no "from" and raises nothing; C<announced_changes>
- the same guard C<t/246> already relies on - means a restarting police or a
second watcher never files a second ticket for the same change.

=cut
