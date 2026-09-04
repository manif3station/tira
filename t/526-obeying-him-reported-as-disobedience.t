#!/usr/bin/env perl
# The rule that reports an agent for doing what the column exists to make it do.
#
# TKT-760, EPC-007. `priority-skipped` reports a card as worked out of turn
# whenever it was taken from the column he uses to hand out work - because
# taking it means moving it out, and moving it out is what destroys the evidence
# that taking it was right.
#
# TKT-383 made a card in the 'next' column outrank everything WHILE IT WAITS.
# work_order reads the role rather than a name, and the comment beside it quotes
# him: "His channel, not the agent's - you do not add card on it. i will add
# which cards on it. A card he moves there must come first, ahead of priority."
#
# But priority-skipped judges the card being WORKED, and by then it has left.
# The rule builds @waiting from work_order, where a card sitting in his column is
# boosted to the front; the same card, one column later, is a ticket with a
# priority and a date. Nothing anywhere records where it came from.
#
# THREE INSTANCES, ALL ON CORRECT PICKS:
#
#   VIO-1789  TKT-747  2026-08-29, escalated NOTE -> WARNING -> URGENT
#   VIO-1794  TKT-745  2026-08-29, raised within seconds of the move
#   VIO-2843  TKT-888  2026-09-04, escalated NOTE -> WARNING over three passes
#
# THE THIRD IS THE ONE THAT DECIDES THE FIX. The first two were same-priority
# complaints - "this one has waited longer" - which a tie-break could soften.
# The third was a genuine rank inversion: TKT-748 at priority 4 really did
# outrank TKT-888 at 3, and the only thing making the pick correct was that he
# had placed it. That fact has to be RECOVERED, not inferred.
#
# WHERE IT IS RECOVERABLE. The move is journalled. history_list(field =>
# 'column') returns entries carrying `before` and `after`, so "was moved out of
# the next column" survives the move that ends the live evidence.
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

# Two queue columns named deliberately. Naming any queue column stops the
# fallback to protected non-ending ones, so backlog has to be named too or it
# silently stops being a queue column the moment next-to-work-on is - a lesson
# t/276 records and this file would otherwise rediscover.
sub board {
    my (%args) = @_;
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Turn', dir => $root,
        members => [ 'claude', 'michael' ], agent => 'claude',
        columns => [ $args{columns} // 'backlog, next-to-work-on, implement, done' ],
        sow_prefix => 'TNS', epic_prefix => 'TNE', ticket_prefix => 'TNT',
    );
    if ( $args{next_role} ) {
        $tira->column_roles_set( project => $root, type => 'ticket',
            roles => { next => $args{next_role} } );
        $tira->column_update( project => $root, type => 'ticket',
            name => $args{next_role}, queue => 1 );
    }
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

# --- the fault: obeying him is reported ---------------------------------------
#
# The shape of the third instance rather than the first two: the worked card is
# genuinely LOWER priority than the one left waiting, so nothing but his
# placement makes the pick correct.

{
    my ( $tira, $root ) = board( next_role => 'next-to-work-on' );

    my $outranking = $tira->create_record( project => $root, type => 'ticket',
        title => 'Higher priority, left in the backlog', priority => 4 );
    my $his = $tira->create_record( project => $root, type => 'ticket',
        title => 'Lower priority, he wants it now', priority => 3 );

    # He places it. The agent never does - that is the whole point of the column.
    $tira->record_move( project => $root, type => 'ticket', ref => $his->{ref},
        column => 'next-to-work-on', author => 'michael' );

    # non-empty is the whole claim: if the boost is not working while the card
    # WAITS, this file is testing a board that never gave the right answer, and
    # the assertion below would pass for a reason that has nothing to do with
    # the bug.
    is( $tira->work_order( project => $root )->[0]{ref}, $his->{ref},
        'while it waits, his card outranks the higher-priority one - TKT-383, '
          . 'and the behaviour this rule then contradicts' );

    # The agent takes it, which means moving it out.
    $tira->record_move( project => $root, type => 'ticket', ref => $his->{ref},
        column => 'implement', author => 'claude' );

    is_deeply( skipped_refs( $tira, $root ), [],
        'A CARD TAKEN FROM HIS COLUMN IS NOT REPORTED AS WORKED OUT OF TURN. '
          . 'Today it is: the boost lives in work_order and applies only while '
          . 'the card is in the column, so the act of picking it up is what '
          . 'removes the evidence that picking it up was right' );
}

# --- the control this fix must not spend --------------------------------------
#
# Criterion 2, and the reason the exemption goes in _priority_skipped_exempt
# rather than in the rule's loop. A rule that stopped reporting genuine
# queue-jumping would be a worse defect than the one being fixed, and it would
# be invisible: nothing complains when a rule falls silent.

{
    my ( $tira, $root ) = board( next_role => 'next-to-work-on' );

    my $outranking = $tira->create_record( project => $root, type => 'ticket',
        title => 'Priority 5, left waiting', priority => 5 );
    my $taken = $tira->create_record( project => $root, type => 'ticket',
        title => 'Priority 1, taken anyway', priority => 1 );

    # Straight from the backlog. He never touched it.
    $tira->record_move( project => $root, type => 'ticket', ref => $taken->{ref},
        column => 'implement', author => 'claude' );

    is_deeply( skipped_refs( $tira, $root ), [ $taken->{ref} ],
        'a card taken out of turn from the BACKLOG is still reported - the '
          . 'check the rule exists for, and the thing this fix must not spend' );
}

# --- the role is read, not the name -------------------------------------------
#
# Criterion 3. work_order already reads column_roles(...)->{next} rather than a
# literal, and the exemption has to do the same or it will work on this board and
# on no other.

{
    my ( $tira, $root ) = board(
        columns   => 'backlog, up-next, implement, done',
        next_role => 'up-next',
    );

    my $outranking = $tira->create_record( project => $root, type => 'ticket',
        title => 'Higher priority', priority => 4 );
    my $his = $tira->create_record( project => $root, type => 'ticket',
        title => 'His pick', priority => 3 );
    $tira->record_move( project => $root, type => 'ticket', ref => $his->{ref},
        column => 'up-next', author => 'michael' );
    $tira->record_move( project => $root, type => 'ticket', ref => $his->{ref},
        column => 'implement', author => 'claude' );

    is_deeply( skipped_refs( $tira, $root ), [],
        'the exemption follows the ROLE to a column called up-next - a fix that '
          . 'matched the string "next-to-work-on" would work on this board and '
          . 'on no other' );
}

{
    my ( $tira, $root ) = board( columns => 'backlog, implement, done' );

    my $outranking = $tira->create_record( project => $root, type => 'ticket',
        title => 'Priority 5, left waiting', priority => 5 );
    my $taken = $tira->create_record( project => $root, type => 'ticket',
        title => 'Priority 1, taken anyway', priority => 1 );
    $tira->record_move( project => $root, type => 'ticket', ref => $taken->{ref},
        column => 'implement', author => 'claude' );

    is_deeply( skipped_refs( $tira, $root ), [ $taken->{ref} ],
        'and a board that declares NO next role behaves exactly as it does '
          . 'today - the exemption cannot fire where there is no column to have '
          . 'come from' );
}

# --- a card in flight keeps its authorisation ---------------------------------
#
# Criterion 4, decided on the card rather than asked: a card already being worked
# stays authorised when he queues a newer one. Two of his standing instructions
# settle it - the pipeline must never pause, and his column governs what is
# picked up NEXT.
#
# It is asserted here because the chosen fix implements it by construction, and a
# fix that read the CURRENT contents of his column instead would fail exactly
# this and pass everything above.

{
    my ( $tira, $root ) = board( next_role => 'next-to-work-on' );

    my $first = $tira->create_record( project => $root, type => 'ticket',
        title => 'He queued this one first', priority => 3 );
    $tira->record_move( project => $root, type => 'ticket', ref => $first->{ref},
        column => 'next-to-work-on', author => 'michael' );
    $tira->record_move( project => $root, type => 'ticket', ref => $first->{ref},
        column => 'implement', author => 'claude' );

    # And then he queues a newer one behind it, at a higher priority.
    my $second = $tira->create_record( project => $root, type => 'ticket',
        title => 'He queued this one after', priority => 5 );
    $tira->record_move( project => $root, type => 'ticket', ref => $second->{ref},
        column => 'next-to-work-on', author => 'michael' );

    is_deeply( skipped_refs( $tira, $root ), [],
        'a card already being worked KEEPS its authorisation when he queues a '
          . 'newer one - his column governs what is picked up next, and '
          . 'stopping an active card to take it is the pause he has forbidden' );
}

done_testing();

__END__

=head1 NAME

526-obeying-him-reported-as-disobedience.t - taking a card from his column

=head1 WHY

TKT-760. C<priority-skipped> reports a card as worked out of turn whenever it
came from the column he uses to hand out work, because taking it means moving it
out and moving it out destroys the evidence. Measured three times on correct
picks, most recently against TKT-888 on 2026-09-04, where the card left waiting
genuinely outranked the one worked.

=head1 WHAT IS ASSERTED

That a card taken from the declared C<next> column raises nothing, with a control
above it proving the C<work_order> boost was working while the card waited - so a
board that never gave the right answer cannot pass this file by accident.

That a card taken out of turn from the backlog is B<still reported>, which is the
check the rule exists for and the thing this fix must not spend.

That the exemption follows the B<role> to a column named something else, and does
not fire on a board that declares no C<next> role.

And that a card already being worked keeps its authorisation when a newer card is
queued behind it - criterion 4, decided on the card from two of his standing
instructions rather than asked. A fix reading the current contents of his column
would fail this one and pass all the others.

=cut
