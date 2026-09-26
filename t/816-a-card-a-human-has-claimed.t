#!/usr/bin/env perl
# priority-skipped's fourth hold: a card a human has explicitly claimed.
#
# TKT-816. priority-skipped already exempts three classes of card sitting
# above the one being worked - an unanswered question, a future start_date,
# a discarded card - but none of them cover the commonest case on an
# agent-run board: a card a human has claimed and will do himself. DD-667
# was a plaintext credential fix the owner answered "No, I'll handle this one
# myself - leave it in todo"; every card worked below it fired priority-skipped
# naming it, because no agent can ever satisfy the hold the rule needed.
#
# Q-184 settled the mechanism: infer from the ABOVE card's assignee being a
# registered person who is not the board's declared agent - no new field, no
# new person-kind metadata, reusing project_new's own --agent (TKT-459) the
# same way card-changed-by-owner already does via _agent_declared_for.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

sub board {
    my (%args) = @_;
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Claimed', dir => $root,
        members => [ 'claude', 'michael' ], agent => 'claude',
        columns => [ 'backlog, implement, done' ],
        sow_prefix => 'CLS', epic_prefix => 'CLE', ticket_prefix => 'CLT',
    );
    $tira->column_update( project => $root, type => 'ticket',
        name => 'backlog', queue => 1 );
    $tira->policy_add( project => $root, rule => 'priority-skipped',
        action => 'log-only', author => 'claude' );
    return ( $tira, $root );
}

sub skipped_refs {
    my ( $tira, $root ) = @_;
    my $violations = $tira->policy_evaluate( project => $root );
    return [ sort map { $_->{ref} }
        grep { ( $_->{rule} // '' ) eq 'priority-skipped' } @{$violations} ];
}

# --- the fault: a card michael claimed is still reported as skipped -----------
#
# DD-667's exact shape: priority 4, in todo (here backlog, the only resting
# column), assigned to a human, while the agent works something lower.

{
    my ( $tira, $root ) = board();

    my $claimed = $tira->create_record( project => $root, type => 'ticket',
        title => 'Plaintext credential - I will handle this myself',
        priority => 4, assignee => 'michael' );
    my $lower = $tira->create_record( project => $root, type => 'ticket',
        title => 'Lower priority, agent-worked', priority => 1 );

    $tira->record_move( project => $root, type => 'ticket', ref => $lower->{ref},
        column => 'implement', author => 'claude' );

    is_deeply( skipped_refs( $tira, $root ), [],
        'A CARD A HUMAN HAS CLAIMED IS NOT REPORTED AS SKIPPED. Today it is: '
          . 'priority-skipped has no hold for an above card assigned to a real '
          . 'person, so the agent is blamed for a card it can never satisfy' );
}

# --- the control this fix must not spend ---------------------------------------
#
# An above card assigned to nobody is not claimed by anybody, and must still
# be reported - the check the rule exists for.

{
    my ( $tira, $root ) = board();

    my $unassigned = $tira->create_record( project => $root, type => 'ticket',
        title => 'Higher priority, nobody has claimed it', priority => 4 );
    my $lower = $tira->create_record( project => $root, type => 'ticket',
        title => 'Lower priority, taken anyway', priority => 1 );

    $tira->record_move( project => $root, type => 'ticket', ref => $lower->{ref},
        column => 'implement', author => 'claude' );

    is_deeply( skipped_refs( $tira, $root ), [ $lower->{ref} ],
        'an UNASSIGNED card left waiting is still reported - nobody has '
          . 'claimed it, so this is exactly the queue-jumping the rule exists '
          . 'to catch' );
}

# --- the agent's own name does not exempt itself --------------------------------
#
# An above card assigned to the board's declared agent is not a human claim -
# it is the agent's own backlog, and skipping it below would silence the rule
# for the one case it is actually supposed to catch.

{
    my ( $tira, $root ) = board();

    my $agents_own = $tira->create_record( project => $root, type => 'ticket',
        title => "Higher priority, assigned to the agent itself",
        priority => 4, assignee => 'claude' );
    my $lower = $tira->create_record( project => $root, type => 'ticket',
        title => 'Lower priority, taken anyway', priority => 1 );

    $tira->record_move( project => $root, type => 'ticket', ref => $lower->{ref},
        column => 'implement', author => 'claude' );

    is_deeply( skipped_refs( $tira, $root ), [ $lower->{ref} ],
        "a card assigned to the AGENT itself is not a human claim - the hold "
          . 'must not exempt the agent from its own queue' );
}

done_testing();

__END__

=head1 NAME

816-a-card-a-human-has-claimed.t - priority-skipped's fourth hold

=head1 WHY

TKT-816. C<priority-skipped> reports work taken out of turn, but had no hold
for the commonest case on an agent-run board: a card a human has explicitly
claimed and will do himself. DD-667, a plaintext credential the owner said he
would fix personally, fired the rule against every card worked below it,
because no agent could ever satisfy that hold.

=head1 WHAT IS ASSERTED

That an above card assigned to a real, registered person other than the
board's declared agent is not reported as skipped - Q-184's chosen mechanism,
reusing C<project_new>'s existing C<--agent> setting rather than a new field
or a new person-kind distinction.

That an UNASSIGNED above card is still reported - nobody has claimed it, so
the queue-jumping check this rule exists for still fires.

That an above card assigned to the AGENT ITSELF is still reported - the hold
is about a human's claim, not about whether the field is merely non-empty.

=cut
