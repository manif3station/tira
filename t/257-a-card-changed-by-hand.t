#!/usr/bin/env perl
# A card the owner changed in the browser is said out loud.
#
# His words: "if the user changed anything on any card on the html dashboard,
# the police will issue a notice on the bridge to remind the agent to check it
# out."
#
# The card is the one place he has been told to put instructions for the agent,
# and until now an edit made there was invisible: he changes it in the browser,
# the agent works from the CLI, and nothing connects the two until the agent
# happens to re-read the card.
#
# The signal already existed and nothing read it. Every route on the browser
# dashboard goes through _attributed, which puts the signed-in person on the
# payload so the engine records who acted, and history entries carry an author.
# Verified on the real board: entries written by the CLI have author null, and
# entries written through the dashboard carry the person.
#
# So this compares rather than remembers - the newest change on the card was
# made by somebody who is not the agent working it - and settles by itself the
# moment the agent touches the card, because the agent's own change becomes the
# newest one. A rule that settled on a promise to look would be worse than none.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-17T09:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Watched', dir => $root, members => [ 'claude', 'michael' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WTS', epic_prefix => 'WTE', ticket_prefix => 'WTT',
);

# The board says which agent works it, which is the fact the rule turns on: an
# edit by that agent is the board's own work whoever the card is assigned to.
$tira->project_update( project => $root, agent => 'claude' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Being worked, and about to be edited underneath', priority => 3,
    assignee => 'claude' );
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );

sub reported {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'card-changed-by-owner' }
          @{ $pass->{violations} } ];
}

# --- the rule exists ------------------------------------------------------------

{
    my %rules = map { $_ => 1 } @{ Tira::policy_rules() };
    ok( $rules{'card-changed-by-owner'}, 'the catalogue offers a rule for this' );
}

$tira->policy_add( project => $root, rule => 'card-changed-by-owner',
    action => 'bridge-reminder' );

# --- an agent working normally is not reported ----------------------------------
#
# Asserted first, so what follows is somebody else's edit rather than a rule
# that fires on everything.

{
    $now = '2026-08-17T10:00:00Z';
    $tira->record_update( author => 'claude', project => $root, ref => $card->{ref},
        solution_needed => 'Written by the agent doing the work.' );

    is_deeply( reported(), [],
        'the agent changing its own card is not reported' );
}

# --- and the owner changing it in the browser is -------------------------------
#
# What the dashboard does: the signed-in person travels with the change, so the
# engine records who acted.

{
    $now = '2026-08-17T11:00:00Z';
    $tira->record_update( project => $root, ref => $card->{ref},
        author => 'michael',
        key_details => ['Do this the other way round - I have changed my mind.'] );

    my $found = reported();
    is( scalar @{$found}, 1, 'a card changed by somebody else is reported' );
    is( $found->[0]{ref}, $card->{ref}, 'naming the card' );
    like( $found->[0]{detail} // '', qr/michael/, 'and who changed it' );
    like( $found->[0]{detail} // '', qr/key_details/,
        'and what they changed, so the agent knows where to look' );
}

# --- and it settles when the agent looks ----------------------------------------
#
# The half that makes it a reminder rather than a permanent complaint. Nothing
# is remembered: the agent's own change is simply the newest one.

{
    $now = '2026-08-17T12:00:00Z';
    $tira->record_update( author => 'claude', project => $root, ref => $card->{ref},
        solution_needed => 'Read it, and doing it his way.' );

    is_deeply( reported(), [],
        'the agent touching the card settles it, with nothing to remember' );
}

# --- an unassigned card, from both sides ----------------------------------------
#
# The case that was wrong when this shipped, and it was wrong in the test first:
# it asserted only that an unassigned card IS reported, which the vacuous
# version satisfied. With no assignee, "somebody other than the agent working
# it" is true of everybody, so the board's own agent counted as an outsider and
# the finding could never settle - the agent's next edit was by the same
# stranger as the last.
#
# Measured on this board within a minute of declaring it: 24 findings, every one
# of them this board's own work. Zenandi reported the same thing from their side
# in the same minute, on the two of their four cards that had no assignee.

{
    my $waiting = $tira->create_record( project => $root, type => 'ticket',
        title => 'Waiting, and edited while it waits', priority => 4 );

    $now = '2026-08-17T13:00:00Z';
    $tira->record_update( project => $root, ref => $waiting->{ref},
        author => 'michael', priority => 5 );

    my ($found) = grep { ( $_->{ref} // '' ) eq $waiting->{ref} } @{ reported() };
    ok( $found, 'a card nobody is assigned is reported too - he edits the waiting ones' );

    # And the agent's own edit to the same card settles it, which is the half
    # that could not happen: reading it is what the message asks for.
    $now = '2026-08-17T13:30:00Z';
    $tira->record_update( project => $root, ref => $waiting->{ref},
        author => 'claude', solution_needed => 'Read his change and carried on.' );

    my ($still) = grep { ( $_->{ref} // '' ) eq $waiting->{ref} } @{ reported() };
    ok( !$still,
        "and the board's own agent touching it settles it, on a card with no assignee" );
}

# --- the board's agent is never the stranger ------------------------------------
#
# Whoever the card is assigned to. An agent acting on somebody else's card is
# still the agent, and reporting that would tell it to go and read its own work.

{
    my $hers = $tira->create_record( project => $root, type => 'ticket',
        title => "Assigned to him, worked by the agent", priority => 3,
        assignee => 'michael' );
    $now = '2026-08-17T14:30:00Z';
    $tira->record_update( project => $root, ref => $hers->{ref},
        author => 'claude', solution_needed => 'The agent did the work on it.' );

    my ($found) = grep { ( $_->{ref} // '' ) eq $hers->{ref} } @{ reported() };
    ok( !$found, "the board's agent is not an outside editor on anybody's card" );
}

# --- a column nobody is watching -------------------------------------------------
#
# Reported by Zenandi within minutes of the last one, from the same board: the
# TKT-287 defect repeating in a rule written after it. Every card rule asks
# which columns to leave alone and this one did not.
#
# The watched flag alone, not the whole resting set. A card waiting in the
# backlog is exactly the kind he edits - the block above asserts one is
# reported - so silencing every resting column would silence the case this rule
# was built for.

# The column here is a WORKING one, changed from done when TKT-320 shipped. This
# block is about the watched flag being a switch, and it used done only because
# it was a convenient column to toggle. A card in a column where work ends is now
# left alone whatever the flag says - Zenandi reported that the rule was
# reporting finished cards nobody could act on - so asserting done is reported
# would now be asserting the defect.

{
    my $reviewed = $tira->create_record( project => $root, type => 'ticket',
        title => 'Sitting in a column nobody watches', priority => 3,
        assignee => 'claude' );
    $tira->record_move(author => 'claude',  project => $root, ref => $reviewed->{ref}, column => 'implement' );

    $now = '2026-08-17T15:00:00Z';
    $tira->record_update( project => $root, ref => $reviewed->{ref},
        author => 'michael', key_details => ['Changed it in the browser.'] );

    my ($watched) = grep { ( $_->{ref} // '' ) eq $reviewed->{ref} } @{ reported() };
    ok( $watched, 'a watched column reports the edit' );

    $tira->column_update( project => $root, type => $_, name => 'implement', watched => 0 )
      for qw(sow epic ticket);

    my ($unwatched) = grep { ( $_->{ref} // '' ) eq $reviewed->{ref} } @{ reported() };
    ok( !$unwatched, 'and a column set to --no-watch does not' );

    $tira->column_update( project => $root, type => $_, name => 'implement', watched => 1 )
      for qw(sow epic ticket);
    ok( ( grep { ( $_->{ref} // '' ) eq $reviewed->{ref} } @{ reported() } ),
        'while watching it again brings it back, so the switch is a switch' );
}

# --- proved by ignoring who made the change -------------------------------------
#
# Without the author, an edit made in the browser is indistinguishable from one
# made by the agent, which is the state he described.

{
    $now = '2026-08-17T14:00:00Z';
    $tira->record_update( project => $root, ref => $card->{ref},
        author => 'michael', key_details => ['Changed again, in the browser.'] );

    ok( scalar @{ reported() }, 'the edit is reported' );

    no warnings 'redefine';
    local *Tira::_card_last_author = sub { return undef };

    is_deeply( reported(), [],
        'and reading no author reports nothing, which is what it did before' );
}

done_testing;

__END__

=head1 NAME

257-a-card-changed-by-hand.t - an owner edit the agent is told about

=head1 DESCRIPTION

The owner edits a card in the browser dashboard; the agent works from the CLI
and finds out when it next happens to re-read the card. The signal was already
recorded - the dashboard puts the signed-in person on every change and history
entries carry an author - and no rule read it.

C<card-changed-by-owner> compares rather than remembers: the newest change was
made by somebody other than the agent working the card. It settles when the
agent touches the card, because the agent's change becomes the newest one.

=cut
