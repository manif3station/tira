#!/usr/bin/env perl
# card-changed-by-owner, on a board that has not said which agent works it.
#
# Reported four times by two projects and discarded twice by me, which is the
# part worth recording. Zenandi raised TKT-315 (an unassigned card cannot settle)
# and zen-framework raised TKT-340 (a card assigned to somebody else cannot
# settle). I tested both on a scratch board, found them working, and discarded
# them. My scratch board declared an agent, because THIS board declares one.
# Every new board declares none. Then it was reported twice more - TKT-376, and
# TKT-381 saying it was escalating on two of their cards.
#
# The cause is one guard. The rule settles on two comparisons:
#
#     next if ( $record->{assignee} // '' ) eq $last->{author};
#     next if $ours ne '' && $ours eq $last->{author};
#
# where $ours is the agent the board names. The second is skipped entirely when
# no agent is declared, so the rule falls back to the assignee comparison alone -
# which the comment directly above it already calls vacuous: "with nobody working
# it, everybody is somebody other than the agent working it, so the board's own
# work counted as an outside edit and the finding could never settle. 24 findings
# on this board within a minute of declaring it."
#
# So a board that cannot answer "was this the agent's own change" must not be
# allowed to declare a rule whose whole job is answering it. That is not a new
# mechanism: card-sandbox-missing already refuses on a project with no git
# repository, and the comment on that refusal is the argument for this one -
# "Refused here rather than discovered later as a violation nobody can clear...
# a policy police cannot follow is worse than no policy, because it reads as
# cover."
#
# The terminal-column half is TKT-320, in the same file because it is the same
# rule: a card in a column where work ends has no agent to remind.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-08-18T13:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

sub board {
    my (%args) = @_;
    my $root = File::Spec->catdir( $tmp, $args{name} );
    $tira->project_new(
        name => $args{name}, dir => $root, members => [ 'claude', 'michael', 'zenandi' ],
        columns => ['backlog, implement, done'],
        sow_prefix => 'A' . $args{p}, epic_prefix => 'B' . $args{p},
        ticket_prefix => 'C' . $args{p},
    );
    $tira->project_update( project => $root, agent => $args{agent} ) if $args{agent};
    return $root;
}

# --- a board that names no agent may not declare it ---------------------------------
#
# The refusal, not the evaluation. A board that cannot answer the question the
# rule asks should be told when it declares the rule, not left to discover it as
# findings nobody can clear.

{
    my $nameless = board( name => 'nameless', p => 'N' );

    my $declared = eval {
        $tira->policy_add( project => $nameless, rule => 'card-changed-by-owner',
            action => 'bridge-reminder' );
        1;
    };
    ok( !$declared, 'a board that has not named its agent cannot declare the rule' );
    like( $@ // '', qr/--agent/,
        'and the refusal names the command that supplies what is missing' );

    # The precedent, asserted here so the two cannot drift: the sibling rule
    # refuses the same way for the same kind of reason.
    my $sandbox = eval {
        $tira->policy_add( project => $nameless, rule => 'card-sandbox-missing',
            enter => 'implement', sandbox => '/s', action => 'log-only' );
        1;
    };
    ok( !$sandbox, 'card-sandbox-missing still refuses a project with no repository' );
}

# --- a board that names one is unaffected --------------------------------------------

my $named = board( name => 'named', p => 'M', agent => 'claude' );

{
    my $declared = eval {
        $tira->policy_add( project => $named, rule => 'card-changed-by-owner',
            action => 'bridge-reminder' );
        1;
    };
    ok( $declared, 'a board that names its agent declares it exactly as before' )
      or diag($@);
}

sub reported {
    my ( $root, $store ) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'card-changed-by-owner' }
          @{ $pass->{violations} } ];
}

my $store = File::Spec->catdir( $tmp, 'police' );

# --- and behaves as measured: fires on his edit, settles on the agent's -------------

{
    my $card = $tira->create_record( project => $named, type => 'ticket',
        title => 'Assigned to somebody else entirely', priority => 3,
        assignee => 'zenandi' );
    $tira->record_move(author => 'claude',  project => $named, ref => $card->{ref}, column => 'implement' );

    $now = '2026-08-18T13:05:00Z';
    $tira->record_update( project => $named, ref => $card->{ref},
        author => 'michael', key_details => ['Changed it in the browser.'] );
    my ($fired) = grep { $_->{ref} eq $card->{ref} } @{ reported( $named, $store ) };
    ok( $fired, 'an owner edit on a card assigned to a third person is reported' );

    $now = '2026-08-18T13:06:00Z';
    $tira->record_update( project => $named, ref => $card->{ref},
        author => 'claude', solution_needed => 'The agent read it.' );
    my ($still) = grep { $_->{ref} eq $card->{ref} } @{ reported( $named, $store ) };
    ok( !$still, 'and the agent touching it settles it - the route the contract names' );
}

# --- a card where work has ended is left alone --------------------------------------
#
# TKT-320, from Zenandi, and the same shape as TKT-287: every card rule asks
# which columns to leave alone, and this one asked the watched flag and never
# whether the column is an ending. A finished card has no agent to remind, so
# the finding has no addressee who can act on it - and TKT-319 records that
# their owner chose to accept permanent CRITICAL noise rather than mute it.

{
    my $done = $tira->create_record( project => $named, type => 'ticket',
        title => 'Finished, and edited afterwards', priority => 3, assignee => 'claude' );
    $tira->record_move(author => 'claude',  project => $named, ref => $done->{ref}, column => 'done' );

    $now = '2026-08-18T13:10:00Z';
    $tira->record_update( project => $named, ref => $done->{ref},
        author => 'michael', key_details => ['Tweaked after it was finished.'] );

    my ($ended) = grep { $_->{ref} eq $done->{ref} } @{ reported( $named, $store ) };
    ok( !$ended, 'a card in a column where work ends is not reported' );
}

# --- while a card still being worked is ----------------------------------------------
#
# Asserted beside it, so the exclusion above cannot be a rule that stopped
# firing altogether.

{
    my $live = $tira->create_record( project => $named, type => 'ticket',
        title => 'Still being worked', priority => 3, assignee => 'claude' );
    $tira->record_move(author => 'claude',  project => $named, ref => $live->{ref}, column => 'implement' );

    $now = '2026-08-18T13:12:00Z';
    $tira->record_update( project => $named, ref => $live->{ref},
        author => 'michael', key_details => ['Changed while it is being worked.'] );

    my ($working) = grep { $_->{ref} eq $live->{ref} } @{ reported( $named, $store ) };
    ok( $working, 'and a card still in a working column is reported as before' );
}

# --- proved by putting each guard back ------------------------------------------------

{
    my $nameless = board( name => 'proof', p => 'P' );

    no warnings 'redefine';
    local *Tira::_agent_declared_for = sub { return 'somebody' };

    my $declared = eval {
        $tira->policy_add( project => $nameless, rule => 'card-changed-by-owner',
            action => 'bridge-reminder' );
        1;
    };
    ok( $declared,
        'with the precondition answered, the declaration is accepted again - so the refusal is the guard and not an accident' );
}

done_testing;

__END__

=head1 NAME

269-a-rule-that-cannot-tell-whose-change-it-was.t - TKT-376, TKT-381 and TKT-320

=head1 DESCRIPTION

C<card-changed-by-owner> settles by comparing the newest author against the agent
the board names. A board that names none falls back to the card's assignee alone,
which the rule's own comment calls vacuous - it counts the board's own work as an
outside edit and the finding can never settle.

Declaring it there is now refused, the way C<card-sandbox-missing> refuses a
project with no git repository. And a card in a column where work ends is left
alone, because a finished card has no agent to remind.

=cut
