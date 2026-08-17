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

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Being worked, and about to be edited underneath', priority => 3,
    assignee => 'claude' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );

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
    $tira->record_update( project => $root, ref => $card->{ref},
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
    $tira->record_update( project => $root, ref => $card->{ref},
        solution_needed => 'Read it, and doing it his way.' );

    is_deeply( reported(), [],
        'the agent touching the card settles it, with nothing to remember' );
}

# --- an unassigned card is still reported ---------------------------------------
#
# Nobody in particular to tell is not a reason to say nothing. He edits cards
# that are waiting, and those are the ones with no assignee.

{
    my $waiting = $tira->create_record( project => $root, type => 'ticket',
        title => 'Waiting, and edited while it waits', priority => 4 );
    $now = '2026-08-17T13:00:00Z';
    $tira->record_update( project => $root, ref => $waiting->{ref},
        author => 'michael', priority => 5 );

    my ($found) = grep { ( $_->{ref} // '' ) eq $waiting->{ref} } @{ reported() };
    ok( $found, 'a card nobody is assigned is reported too' );
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
