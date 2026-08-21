#!/usr/bin/env perl
# The order work is taken in is checked by something other than the agent.
#
# He caught it himself: "can you also working on the higher prioity cards
# first, i see you randomly pick and work on them disregard the card prioity".
# The fix at the time was a sentence written into a document - which is exactly
# the kind of check this project has learned not to trust, because the party
# that promised is the party that would have to notice it had stopped.
#
# It is worth a rule rather than a habit for a sharper reason. The agent raises
# its own cards and sets their priority, so "work the highest first" is a weak
# promise when the same party decides what is highest: anything can be made P1
# and the order is always satisfied. What a rule can watch is the part that
# cannot be marked as its own homework - not what priority was set, but whether
# something above the card being worked is being left alone.
#
# The hard half is telling a skipped card from a parked one. A higher card
# waiting on an answer from the owner is not being ignored, and a rule that
# could not tell those apart would fire on every board that has ever waited for
# anything, which is how a channel stops being read.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-14T20:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Order', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ORS', epic_prefix => 'ORE', ticket_prefix => 'ORT',
);

sub card {
    my (%args) = @_;
    my $made = $tira->create_record( project => $root, type => $args{type} // 'ticket',
        title => $args{title}, priority => $args{priority} );
    $tira->record_move(author => 'claude',  project => $root, ref => $made->{ref}, column => $args{column} )
      if $args{column};
    return $made->{ref};
}

sub reported {
    my $pass = $tira->police_pass( project => $root, store => $store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    return [ grep { $_->{rule} eq 'priority-skipped' } @{ $pass->{violations} } ];
}

# --- a board that has not asked hears nothing ------------------------------------
#
# First, because a rule that arrives switched on changes every board that
# upgrades, underneath whoever was relying on them.

# 5 is the urgent end here, which TKT-186 settled and wrote down. This file's
# first draft had these the other way round - the waiting card at 1 and the
# worked card at 4 - so it asserted a violation on work taken in the CORRECT
# order, and would have shipped a rule enforcing the exact opposite of what was
# asked for while looking like a guard.
my $waiting = card( title => 'The one that should have gone first', priority => 5 );
my $working = card( title => 'The one being worked instead', priority => 2, column => 'implement' );

is( scalar @{ reported() }, 0, 'a board that has not declared the rule hears nothing' );

$tira->policy_add( project => $root, rule => 'priority-skipped', action => 'bridge-reminder' );

# --- work taken out of turn ---------------------------------------------------------

my $found = reported();
is( scalar @{$found}, 1, 'a card worked while a higher one waits is reported' );
like( $found->[0]{detail}, qr/\Q$waiting\E/, 'naming the card that should have gone first' );
is( $found->[0]{ref}, $working, 'against the card actually being worked, which is the one to move' );
like( $found->[0]{detail}, qr/\b5\b/, 'and saying what priority was passed over' );

# --- work taken in order says nothing --------------------------------------------------
#
# The half that decides whether this is a rule or a nuisance.

{
    my $order = File::Spec->catdir( $tmp, 'order' );
    my $quiet = File::Spec->catdir( $tmp, 'police-order' );
    $tira->project_new(
        name => 'InOrder', dir => $order, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'IOS', epic_prefix => 'IOE', ticket_prefix => 'IOT',
    );
    $tira->policy_add( project => $order, rule => 'priority-skipped', action => 'bridge-reminder' );

    my $top = $tira->create_record( project => $order, type => 'ticket',
        title => 'Worked first, as it should be', priority => 5 );
    $tira->record_move(author => 'claude',  project => $order, ref => $top->{ref}, column => 'implement' );
    $tira->create_record( project => $order, type => 'ticket',
        title => 'Waiting its turn', priority => 3 );    # below 5, so its turn has not come

    my $pass = $tira->police_pass( project => $order, store => $quiet,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is_deeply( [ grep { $_->{rule} eq 'priority-skipped' } @{ $pass->{violations} } ], [],
        'work taken in order says nothing at all' );
}

# --- a card waiting on him is parked, not skipped -----------------------------------------
#
# The exemption that keeps this usable. A higher card that cannot move until he
# answers is not being ignored, and reporting it would blame the agent for the
# one delay that is not its doing.

{
    my $question = $tira->question_add( project => $root, ref => $waiting, author => 'claude',
        text => 'Which way should this go?', reason => 'It cannot start until this is settled' );

    is( scalar @{ reported() }, 0,
        'a higher card waiting on an unanswered question is parked, not skipped' );

    # And the moment he answers, it is the agent's again.
    $tira->question_answer( project => $root, ref => $waiting, id => $question->{id},
        author => 'michael', text => 'That way' );
    is( scalar @{ reported() }, 1,
        'once it is answered the excuse is gone and the card is reported again' );
}

# --- cards of different kinds are not compared ----------------------------------------------
#
# An epic sits in the backlog for as long as its tickets take, which is what an
# epic is for. Judging a ticket against it would make every board with a
# hierarchy permanently in violation.

{
    card( type => 'epic', title => 'A container, not a queue', priority => 5 );
    my $after = reported();

    # scalar @$after rather than scalar @{$after}: t/147 requires a denial's
    # subject to be established by a positive assertion first, and recognises
    # the sigil form. The braced form reads identically to a person and not at
    # all to the guard.
    is( scalar @$after, 1, 'an epic waiting above a ticket is not a card taken out of turn' );
    unlike( $after->[0]{detail}, qr/ORE-/, 'and the epic is not named' );
}

# --- a card with no priority is not treated as urgent ------------------------------------------
#
# Unset is unknown, not zero. A board that has never used priorities would
# otherwise be told every card is being skipped.

{
    my $none = File::Spec->catdir( $tmp, 'nopri' );
    my $silence = File::Spec->catdir( $tmp, 'police-nopri' );
    $tira->project_new(
        name => 'NoPriority', dir => $none, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'NPS', epic_prefix => 'NPE', ticket_prefix => 'NPT',
    );
    $tira->policy_add( project => $none, rule => 'priority-skipped', action => 'bridge-reminder' );
    my $doing = $tira->create_record( project => $none, type => 'ticket', title => 'Being worked' );
    $tira->record_move(author => 'claude',  project => $none, ref => $doing->{ref}, column => 'implement' );
    $tira->create_record( project => $none, type => 'ticket', title => 'Sitting in the backlog' );

    my $pass = $tira->police_pass( project => $none, store => $silence,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is_deeply( [ grep { $_->{rule} eq 'priority-skipped' } @{ $pass->{violations} } ], [],
        'a board that sets no priorities is not told its order is wrong' );
}

# --- a finished card is not a card waiting its turn --------------------------------------------
#
# A board that marks where work ends has cards resting there for ever, and the
# most urgent work a project ever did is usually the work it has already done.
# Counting those as waiting would put such a board permanently in violation of
# its own history.
#
# Added because a coverage run found the branch that reads terminal columns had
# never executed: no test declared this rule on a board that marks one. The
# comment beside the code claimed to handle exactly this and nothing asked it to.

{
    my $ended = File::Spec->catdir( $tmp, 'ended' );
    my $quiet = File::Spec->catdir( $tmp, 'police-ended' );
    $tira->project_new(
        name => 'Ended', dir => $ended, members => ['claude'],
        columns => ['backlog, implement, shipped'],
        sow_prefix => 'EDS', epic_prefix => 'EDE', ticket_prefix => 'EDT',
    );
    $tira->column_update( project => $ended, type => 'ticket', name => 'shipped', terminal => 1 );
    $tira->policy_add( project => $ended, rule => 'priority-skipped', action => 'bridge-reminder' );

    my $finished = $tira->create_record( project => $ended, type => 'ticket',
        title => 'The most urgent thing we ever did, and it is done', priority => 5 );
    $tira->record_move(author => 'claude',  project => $ended, ref => $finished->{ref}, column => 'shipped' );

    my $doing = $tira->create_record( project => $ended, type => 'ticket',
        title => 'Being worked now', priority => 2 );
    $tira->record_move(author => 'claude',  project => $ended, ref => $doing->{ref}, column => 'implement' );

    my $pass = $tira->police_pass( project => $ended, store => $quiet,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is_deeply( [ grep { $_->{rule} eq 'priority-skipped' } @{ $pass->{violations} } ], [],
        'a finished card is not counted as one waiting its turn' );
}

# --- an unprioritised card waiting is not a card being skipped -------------------------------
#
# Unset is unassessed, not urgent. A card nobody has given a number to is one
# nobody has judged, and treating it as the top of the queue would stop work on
# a board the moment somebody raised a card and did not finish thinking about
# it.
#
# Added after a mutation found nothing. Breaking the check on the WAITING side
# left every assertion green, because the only case here with no priorities had
# none on either side and was stopped by the check on the worked card instead.
# One guard was doing all the work and the other had never been asked.

{
    my $mixed = File::Spec->catdir( $tmp, 'mixed' );
    my $quiet = File::Spec->catdir( $tmp, 'police-mixed' );
    $tira->project_new(
        name => 'Mixed', dir => $mixed, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'MXS', epic_prefix => 'MXE', ticket_prefix => 'MXT',
    );
    $tira->policy_add( project => $mixed, rule => 'priority-skipped', action => 'bridge-reminder' );

    my $doing = $tira->create_record( project => $mixed, type => 'ticket',
        title => 'Being worked, and assessed', priority => 2 );
    $tira->record_move(author => 'claude',  project => $mixed, ref => $doing->{ref}, column => 'implement' );

    # No priority at all - raised and not yet judged.
    $tira->create_record( project => $mixed, type => 'ticket',
        title => 'Raised, never assessed' );

    # Warnings collected, because they are what distinguishes the guard here
    # from dead code. Removing the check on the waiting side changes no verdict
    # - an unset priority numifies to zero and never outranks a real one - so
    # the only thing it does is keep the comparison from reading an undefined
    # value, and "Use of uninitialized value in numeric le" is the difference.
    # Without this assertion the check would be unexercised and would look
    # removable to anybody tidying up.
    my @warnings;
    my $pass = do {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $tira->police_pass( project => $mixed, store => $quiet,
            world => { branches => [], worktrees => [], processes => [], containers => [] } );
    };
    is_deeply( [ grep { $_->{rule} eq 'priority-skipped' } @{ $pass->{violations} } ], [],
        'a card nobody has prioritised is not treated as the top of the queue' );
    is_deeply( \@warnings, [],
        'and the pass reads no undefined value working that out' );
}

# --- and the rule refuses arguments it cannot use -------------------------------------------
#
# A policy police cannot follow is worse than no policy, because it reads as
# cover. This rule has no age: a card being skipped does not become more skipped
# by waiting, and the quiet ladder already stops it being said twice a minute.

ok( !eval {
        $tira->policy_add( project => $root, rule => 'priority-skipped',
            age => '2h', action => 'bridge-reminder' );
        1;
    },
    'an age is refused, because being passed over is not a thing that ripens' );

done_testing;

__END__

=head1 NAME

171-a-card-worked-out-of-turn.t - work order is checked by something other than the agent

=head1 DESCRIPTION

C<priority-skipped> reports a card being worked while a higher-priority card of
the same kind sits untouched in the backlog, naming both. It exists because the
agent both raises the cards and sets their priority, so working the highest
first is a promise the promising party would have to notice breaking.

A higher card waiting on an unanswered question is parked rather than skipped
and is not reported until the answer arrives. Cards of different kinds are not
compared, because an epic sits in the backlog for as long as its tickets take.
A card with no priority is unknown rather than urgent, so a board that has
never used priorities hears nothing.

=cut
