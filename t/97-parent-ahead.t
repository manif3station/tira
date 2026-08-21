#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-12T09:00:00Z' } );

my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Ahead', dir => $root, members => ['claude'],
    columns => ['backlog, doing, archived, discard'],
    sow_prefix => 'AHS', epic_prefix => 'AHE', ticket_prefix => 'AHT',
);

# The vocabulary is the project's own, so which column means finished is
# declared rather than guessed. This board calls it 'archived' on purpose: a
# rule that looks for a column called 'done' says nothing on a board that
# does not have one, silently, which is the worst way for a rule to fail.
$tira->column_roles_set( project => $root, type => 'epic', roles => { done => 'archived' } );
$tira->column_roles_set( project => $root, type => 'ticket', roles => { done => 'archived' } );

$tira->policy_add( project => $root, rule => 'parent-ahead-of-children',
    action => 'bridge-reminder' );

my $epic = $tira->create_record( project => $root, type => 'epic', title => 'The parent' );
my $child = $tira->create_record( project => $root, type => 'ticket', title => 'The child' );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $child->{ref} );

sub violations {
    return [ grep { $_->{rule} eq 'parent-ahead-of-children' }
          @{ $tira->policy_evaluate( project => $root ) } ];
}

# --- while the parent is still open ---------------------------------------

is_deeply( violations(), [], 'a parent that has not claimed to be finished is nobody\'s business' );

# --- the parent claims to be finished -------------------------------------

# Michael photographed exactly this: an epic in done with a ticket in backlog
# underneath it, an hour after he had asked for that ticket. The board said the
# work was finished when it had not begun.
$tira->record_move(author => 'claude',  project => $root, ref => $epic->{ref}, column => 'archived' );

my $reported = violations();
is( scalar @{$reported}, 1, 'a finished parent with a live child is reported' );
is( $reported->[0]{ref}, $epic->{ref}, 'against the parent, which is the card telling the lie' );
like( $reported->[0]{detail}, qr/\Q$child->{ref}\E/,
    'and it names the child, so nobody has to go looking for which one' );

# --- the child settles ----------------------------------------------------

$tira->record_move(author => 'claude',  project => $root, ref => $child->{ref}, column => 'archived' );
is_deeply( violations(), [], 'and it stops the moment the child is finished too' );

# --- a discarded child is settled -----------------------------------------

# Discarding is a decision, not unfinished work.
my $dropped = $tira->create_record( project => $root, type => 'ticket', title => 'Not worth doing' );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $dropped->{ref} );
is( scalar @{ violations() }, 1, 'a new live child brings it back' );

$tira->record_discard(author => 'claude',  project => $root, ref => $dropped->{ref} );
is_deeply( violations(), [], 'and discarding that child settles it, because a decision is not unfinished work' );

# --- every level, because a parent is a parent -----------------------------

# Michael's correction: this is not epics above tickets, it is any parent above
# any child. A statement of work above its epics and a ticket above its
# sub-tickets are the same relationship, and a rule that understood only one of
# them would be silent on the other two - silent in the way that lets somebody
# believe they are protected.
{
    $tira->column_roles_set( project => $root, type => 'sow', roles => { done => 'archived' } );

    my $sow = $tira->create_record( project => $root, type => 'sow', title => 'The statement of work' );
    $tira->hierarchy_link( project => $root, parent => $sow->{ref}, child => $epic->{ref} );
    $tira->record_move(author => 'claude',  project => $root, ref => $epic->{ref}, column => 'doing' );
    $tira->record_move(author => 'claude',  project => $root, ref => $sow->{ref}, column => 'archived' );

    my ($above_epics) = grep { $_->{ref} eq $sow->{ref} } @{ violations() };
    ok( $above_epics, 'a statement of work finished above an open epic is reported' );
    like( $above_epics->{detail}, qr/\Q$epic->{ref}\E/, 'naming the epic' );

    $tira->record_move(author => 'claude',  project => $root, ref => $sow->{ref}, column => 'backlog' );
    $tira->record_move(author => 'claude',  project => $root, ref => $epic->{ref}, column => 'archived' );
}

{
    # A ticket above a ticket is a sub-item rather than a hierarchy link -
    # hierarchy is SOW to epic and epic to ticket only - so this is the third
    # relationship rather than a repeat of the second, and worth its own proof.
    my $parent_ticket = $tira->create_record( project => $root, type => 'ticket', title => 'A ticket with work under it' );
    my $sub = $tira->create_record( project => $root, type => 'ticket', title => 'A sub-ticket' );
    $tira->subitem_link( project => $root, parent => $parent_ticket->{ref}, child => $sub->{ref} );
    $tira->record_move(author => 'claude',  project => $root, ref => $parent_ticket->{ref}, column => 'archived' );

    my ($above_sub) = grep { $_->{ref} eq $parent_ticket->{ref} } @{ violations() };
    ok( $above_sub, 'a ticket finished above an open sub-ticket is reported' );
    like( $above_sub->{detail}, qr/\Q$sub->{ref}\E/, 'naming the sub-ticket' );

    $tira->record_move(author => 'claude',  project => $root, ref => $sub->{ref}, column => 'archived' );
    is_deeply( [ grep { $_->{ref} eq $parent_ticket->{ref} } @{ violations() } ], [],
        'and silent once the sub-ticket is finished too' );
}

# --- a board that never said which column means finished ------------------

# A rule that guesses at a column name is a rule that quietly protects nothing.
{
    my $other = File::Spec->catdir( $tmp, 'unnamed' );
    $tira->project_new(
        name => 'Unnamed', dir => $other, members => ['claude'],
        columns => ['backlog, shipped, discard'],
        sow_prefix => 'UNS', epic_prefix => 'UNE', ticket_prefix => 'UNT',
    );
    $tira->policy_add( project => $other, rule => 'parent-ahead-of-children',
        action => 'bridge-reminder' );

    my $parent = $tira->create_record( project => $other, type => 'epic', title => 'Parent' );
    my $kid = $tira->create_record( project => $other, type => 'ticket', title => 'Child' );
    $tira->hierarchy_link( project => $other, parent => $parent->{ref}, child => $kid->{ref} );
    $tira->record_move(author => 'claude',  project => $other, ref => $parent->{ref}, column => 'shipped' );

    my @found = grep { $_->{rule} eq 'parent-ahead-of-children' }
      @{ $tira->policy_evaluate( project => $other ) };
    is( scalar @found, 0,
        'a board that has not said which column means finished is not guessed at' );

    my @unresolved = grep { $_->{policy} } @{ $tira->policy_unresolved( project => $other ) };
    ok( scalar @unresolved,
        'and the policy is reported as unresolved, so the silence is visible rather than assumed' );
}

done_testing;

__END__

=head1 NAME

97-parent-ahead.t - a parent that says it is finished while its children are not

=head1 DESCRIPTION

Michael's, by photograph: an epic sitting in done with a ticket in backlog
underneath it, an hour after he had asked for that ticket, and a statement of
work in done above both epics. His words: that is a good example to have a
policy setup - children not done but parent marked as done, that should be
spotted by the police.

It is the checklist lie one level up, and in the direction that overstates
progress. Every other check on this board looks at a card on its own, so
nothing was ever going to see it.

Which column means finished comes from the board's roles rather than from a
name, because a rule that looks for a column called 'done' says nothing at all
on a project that calls it something else - and says it silently, which is the
worst way for a rule somebody believes in to fail. A board that has not
declared the role is reported as unresolved instead, so the silence can be seen.

=cut
