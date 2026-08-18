#!/usr/bin/env perl
# A card he moves to his column comes first, ahead of priority.
#
# He built a next-to-work-on column: "created a next-to-work-on that column is
# for me to move the cards there. If I want which specific cards work on next to
# reprioitize your work" - and was explicit about who moves cards there: "you do
# not add card on it. i will add which cards on it. when you pick the next card,
# this column will be your next to pick first" and "if empty then pick from
# backlog the most high priority ones."
#
# work_order picked by priority alone, so a card he placed there was picked on
# its priority like any other - which is precisely what he asked not to happen.
# Demonstrated live on 2026-08-18: he moved TKT-338 (P2) into next-to-work-on,
# the agent picked it up as instructed, and priority-skipped fired within a
# minute because TKT-383 (P5) was still waiting - the ordering had no notion of
# his column meaning anything at all.
#
# The column's NAME is this project's own - "'Next To Work On' is a label of a
# column only apply on the project. The thing is, other project might use
# another name that you need to consider that factor" - so this is read through
# a role rather than a hardcoded name.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );

sub board {
    my (%args) = @_;
    my $tira = Tira->new( clock => sub {'2026-08-18T18:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, $args{name} );
    $tira->project_new(
        name    => $args{name},
        dir     => $root,
        members => ['claude'], agent => 'claude',
        columns => [ $args{columns} // 'backlog, next-to-work-on, implement, done' ],
        sow_prefix => uc( substr( $args{name}, 0, 2 ) ) . 'S',
        epic_prefix => uc( substr( $args{name}, 0, 2 ) ) . 'E',
        ticket_prefix => uc( substr( $args{name}, 0, 2 ) ) . 'T',
    );
    return ( $tira, $root );
}

# --- a card in his column comes first, whatever its priority ---------------------------

{
    my ( $tira, $root ) = board( name => 'roled' );
    $tira->column_roles_set( project => $root, type => 'ticket',
        roles => { next => 'next-to-work-on' } );
    $tira->column_update( project => $root, type => 'ticket',
        name => 'next-to-work-on', queue => 1 );
    # Naming any queue column stops the fallback to protected non-ending ones -
    # a lesson from earlier this session. backlog must be named too, or it
    # silently stops being a queue column the moment next-to-work-on is.
    $tira->column_update( project => $root, type => 'ticket',
        name => 'backlog', queue => 1 );

    my $p5 = $tira->create_record( project => $root, type => 'ticket',
        title => 'Urgent by priority', priority => 5 );
    my $p1 = $tira->create_record( project => $root, type => 'ticket',
        title => 'Small job he wants now', priority => 1 );
    $tira->record_move( project => $root, type => 'ticket', ref => $p1->{ref},
        column => 'next-to-work-on' );

    my $offered = $tira->work_order( project => $root, type => 'ticket' );
    is( $offered->[0]{ref}, $p1->{ref},
        'the P1 he placed in his column is offered ahead of the P5' );
}

# --- emptying his column restores the ordinary order --------------------------------
#
# The fallback his own words describe: "if empty then pick from backlog the most
# high priority ones."

{
    my ( $tira, $root ) = board( name => 'emptied' );
    $tira->column_roles_set( project => $root, type => 'ticket',
        roles => { next => 'next-to-work-on' } );
    $tira->column_update( project => $root, type => 'ticket',
        name => 'next-to-work-on', queue => 1 );
    # Naming any queue column stops the fallback to protected non-ending ones -
    # a lesson from earlier this session. backlog must be named too, or it
    # silently stops being a queue column the moment next-to-work-on is.
    $tira->column_update( project => $root, type => 'ticket',
        name => 'backlog', queue => 1 );

    my $p5 = $tira->create_record( project => $root, type => 'ticket',
        title => 'Urgent by priority', priority => 5 );
    $tira->create_record( project => $root, type => 'ticket',
        title => 'Ordinary work', priority => 2 );

    my $offered = $tira->work_order( project => $root, type => 'ticket' );
    is( $offered->[0]{ref}, $p5->{ref},
        'with his column empty, the highest-priority card is offered as before' );
}

# --- an undeclared role changes nothing -------------------------------------------------
#
# Every board that has never declared this role must see byte-identical
# ordering to before this feature existed - proved by comparing against the
# same board with the new comparison disabled, not merely by asserting a
# plausible-looking order.

{
    my ( $tira, $root ) = board( name => 'undeclared' );
    $tira->create_record( project => $root, type => 'ticket',
        title => 'A', priority => 3 );
    $tira->create_record( project => $root, type => 'ticket',
        title => 'B', priority => 3 );

    my $before = $tira->work_order( project => $root, type => 'ticket' );
    my @refs_before = map { $_->{ref} } @{$before};

    no warnings 'redefine';
    local *Tira::column_roles = sub { return {} };
    my $forced_off = $tira->work_order( project => $root, type => 'ticket' );
    my @refs_forced = map { $_->{ref} } @{$forced_off};

    is_deeply( \@refs_before, \@refs_forced,
        'an undeclared role orders identically to the role lookup returning nothing at all' );
}

# --- a card mid-flight is never pulled forward, whatever column it sits in -----------
#
# next-to-work-on is itself a queue column ('queue: true' on the live board), so
# this is not a new guard - it is the existing _queue_columns membership still
# doing its job. Asserted anyway, because it is the exact failure mode a careless
# implementation could reintroduce.

{
    my ( $tira, $root ) = board( name => 'midflight' );
    $tira->column_roles_set( project => $root, type => 'ticket',
        roles => { next => 'implement' } );

    my $p1 = $tira->create_record( project => $root, type => 'ticket',
        title => 'Already being worked', priority => 1 );
    $tira->record_move( project => $root, type => 'ticket', ref => $p1->{ref},
        column => 'implement' );
    my $p5 = $tira->create_record( project => $root, type => 'ticket',
        title => 'Waiting in backlog', priority => 5 );

    my $offered = $tira->work_order( project => $root, type => 'ticket' );
    ok( ( grep { $_->{ref} eq $p5->{ref} } @{$offered} ),
        'the backlog card is offered' );
    ok( !( grep { $_->{ref} eq $p1->{ref} } @{$offered} ),
        'the card mid-flight in implement is never offered, role or no role' );
}

# --- nothing writes to his column ----------------------------------------------------
#
# His words: "you do not add card on it. i will add which cards on it." Asserted
# explicitly so a later convenience cannot quietly add a write path.

{
    my ( $tira, $root ) = board( name => 'readonly' );
    $tira->column_roles_set( project => $root, type => 'ticket',
        roles => { next => 'next-to-work-on' } );
    $tira->column_update( project => $root, type => 'ticket',
        name => 'next-to-work-on', queue => 1 );
    # Naming any queue column stops the fallback to protected non-ending ones -
    # a lesson from earlier this session. backlog must be named too, or it
    # silently stops being a queue column the moment next-to-work-on is.
    $tira->column_update( project => $root, type => 'ticket',
        name => 'backlog', queue => 1 );
    $tira->create_record( project => $root, type => 'ticket',
        title => 'Ordinary', priority => 3 );

    $tira->work_order( project => $root, type => 'ticket' );
    $tira->work_order( project => $root, type => 'ticket' );

    my $in_his_column = $tira->record_list( project => $root, type => 'ticket',
        column => 'next-to-work-on' );
    is( scalar @{$in_his_column}, 0, 'work_order never writes a card into his column' );
}

# --- proved by removing the comparison ------------------------------------------------

{
    my ( $tira, $root ) = board( name => 'proof' );
    $tira->column_roles_set( project => $root, type => 'ticket',
        roles => { next => 'next-to-work-on' } );
    $tira->column_update( project => $root, type => 'ticket',
        name => 'next-to-work-on', queue => 1 );
    # Naming any queue column stops the fallback to protected non-ending ones -
    # a lesson from earlier this session. backlog must be named too, or it
    # silently stops being a queue column the moment next-to-work-on is.
    $tira->column_update( project => $root, type => 'ticket',
        name => 'backlog', queue => 1 );

    my $p5 = $tira->create_record( project => $root, type => 'ticket',
        title => 'Urgent by priority', priority => 5 );
    my $p1 = $tira->create_record( project => $root, type => 'ticket',
        title => 'His pick', priority => 1 );
    $tira->record_move( project => $root, type => 'ticket', ref => $p1->{ref},
        column => 'next-to-work-on' );

    no warnings 'redefine';
    local *Tira::column_roles = sub { return {} };
    my $without_the_fix = $tira->work_order( project => $root, type => 'ticket' );
    is( $without_the_fix->[0]{ref}, $p5->{ref},
        'without the role comparison, the P5 wins and his P1 loses - the exact bug this fixes' );
}

done_testing;

__END__

=head1 NAME

276-his-column-comes-first.t - TKT-383

=head1 DESCRIPTION

C<work_order> ordered strictly by priority, so a card he moved into
next-to-work-on to reprioritise the agent's work was picked on its priority
like any other card. It now reads which column plays the C<next> role, per
type, and offers a card sitting there ahead of priority - falling back to the
existing priority order when the role is undeclared or the column is empty.

=cut
