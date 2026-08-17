#!/usr/bin/env perl
# A board says which of its columns work waits in.
#
# Reported by mt5-ai and measured on their board: tira.next answered with
# nothing while three cards sat waiting, prioritised and fully filled in. Their
# queue columns are buglist and new-enhancements, which they created, so
# protected is False on both and always will be - protected means Tira owns the
# column. Waiting was defined as protected-and-not-an-ending, so their waiting
# cards were invisible by construction rather than by mistake.
#
# The consequence they were more worried about, and rightly: work_order is one
# method serving tira.next and priority-skipped both, so priority-skipped went
# structurally silent on that board at the same moment. A rule that cannot fire
# is worse than one that fires wrongly, because nothing tells you.
#
# Their diagnosis is the fix: protected is a statement about WHO OWNS a column
# and it was doing duty as a statement about what the column MEANS. Those come
# apart the moment a board adds columns of its own.
#
# So a board can say it, with --queue, alongside --terminal and --watch. A board
# that says nothing keeps exactly what it has - the same shape as the terminal
# default in 2.46, and for the same reason: a default is there to be right about
# the common case, not to be the only answer available.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $tira  = Tira->new( clock => sub {'2026-08-17T15:00:00Z'} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Queued', dir => $root, members => ['claude'],
    columns => ['backlog, buglist, implement, done'],
    sow_prefix => 'QUS', epic_prefix => 'QUE', ticket_prefix => 'QUT',
);
$tira->policy_add( project => $root, rule => 'priority-skipped',
    action => 'bridge-reminder' );

my $queued = $tira->create_record( project => $root, type => 'ticket',
    title => 'Waiting in a column this board invented', priority => 5 );
$tira->record_move( project => $root, ref => $queued->{ref}, column => 'buglist' );

my $lesser = $tira->create_record( project => $root, type => 'ticket',
    title => 'Less urgent, and about to be worked out of turn', priority => 2 );
$tira->record_move( project => $root, ref => $lesser->{ref}, column => 'buglist' );

# --- the board as they found it -------------------------------------------------
#
# Their measurement, reproduced: cards waiting, and nothing offered.

is_deeply( $tira->work_order( project => $root ), [],
    'a board queueing work in its own column is offered nothing, which is what they measured' );

# --- and once the board says which column is its queue --------------------------

{
    $tira->column_update( project => $root, type => $_, name => 'buglist', queue => 1 )
      for qw(sow epic ticket);

    my $order = $tira->work_order( project => $root );
    is( scalar @{$order}, 2, 'saying so makes the waiting cards visible' );
    is( $order->[0]{ref}, $queued->{ref},
        'in the order the board enforces everywhere else' );
}

# --- and the rule can fire again ------------------------------------------------
#
# The half that worried them more. A rule that cannot fire says nothing about a
# board that is behaving, and nothing about one that is not.

{
    $tira->record_move( project => $root, ref => $lesser->{ref}, column => 'implement' );

    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    my @skipped = grep { ( $_->{rule} // '' ) eq 'priority-skipped' }
      @{ $pass->{violations} };

    ok( scalar @skipped, 'working the lesser card out of turn is reported again' );
    like( $skipped[0]{detail} // '', qr/\Q$queued->{ref}\E/,
        'naming the card that was passed over' );
}

# --- a board that says nothing is unchanged --------------------------------------
#
# The whole risk of this change. Every board running today declared no queue,
# and none of them should notice.

{
    my $plain = File::Spec->catdir( $tmp, 'plain' );
    $tira->project_new(
        name => 'Plain', dir => $plain, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'PLS', epic_prefix => 'PLE', ticket_prefix => 'PLT',
    );
    my $waiting = $tira->create_record( project => $plain, type => 'ticket',
        title => 'Waiting in the backlog, as boards have always done', priority => 4 );

    my $order = $tira->work_order( project => $plain );
    is( scalar @{$order}, 1, 'a board that declares no queue still offers its backlog' );
    is( $order->[0]{ref}, $waiting->{ref}, 'which is the card waiting in it' );
}

# --- and a queue named explicitly replaces the assumption ------------------------
#
# Not adds to it. A board that has said which column is its queue has answered
# the question, and a backlog it did not name is not a second answer.

{
    my $both = File::Spec->catdir( $tmp, 'both' );
    $tira->project_new(
        name => 'Both', dir => $both, members => ['claude'],
        columns => ['backlog, buglist, implement, done'],
        sow_prefix => 'BTS', epic_prefix => 'BTE', ticket_prefix => 'BTT',
    );
    my $in_backlog = $tira->create_record( project => $both, type => 'ticket',
        title => 'Sitting in the backlog', priority => 5 );
    my $in_queue = $tira->create_record( project => $both, type => 'ticket',
        title => 'Sitting in the named queue', priority => 3 );
    $tira->record_move( project => $both, ref => $in_queue->{ref}, column => 'buglist' );

    $tira->column_update( project => $both, type => $_, name => 'buglist', queue => 1 )
      for qw(sow epic ticket);

    my $order = $tira->work_order( project => $both );
    is_deeply( [ map { $_->{ref} } @{$order} ], [ $in_queue->{ref} ],
        'the named queue is the answer, and the unnamed backlog is not a second one' );
}

# --- and the rule that looks for unpoliced columns leaves it alone ----------------
#
# Found by the hourly bug hunt rather than reported: column-unwatched kept its
# own copy of what a working column is - not protected and not an ending - which
# is the mirror image of the definition this card replaced. The two agreed until
# this fix, and then disagreed by construction: a column a board created is never
# protected, so a queue looked like a place work happens that no policy mentions.
#
# On the reporting board that means being asked to declare gate-missing or
# checklist-idle on a queue, which is the absurdity that rule's own comment says
# it exists to avoid. TKT-330.

{
    # A column-scoped policy has to exist for this rule to have anything to
    # compare against - a board with none is a board that has not started, and
    # reporting every column at once would tell it nothing.
    $tira->policy_add( project => $root, rule => 'column-unwatched',
        action => 'bridge-reminder' );
    $tira->policy_add( project => $root, rule => 'card-duration',
        action => 'log-only', column => 'implement', age => '4h' );

    # And a working column nobody has named, so the rule has a true finding to
    # make alongside the queue it must leave alone. Without one it would go
    # quiet for the right reason and this block would prove nothing.
    $tira->column_add( project => $root, type => $_, name => 'verify' )
      for qw(sow epic ticket);

    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    my @unwatched = grep { ( $_->{rule} // '' ) eq 'column-unwatched' }
      @{ $pass->{violations} };

    my $said = join ' ', map { $_->{detail} // '' } @unwatched;
    # The subject established before it is denied: verify is a working column
    # nobody has named a policy for, so the rule has something true to say and
    # $said is not empty. Without this the denial below would pass on an empty
    # string, which is the shape t/147 exists to catch - and did catch, here.
    like( $said, qr/\bverify\b/,
        'the rule names a working column no policy mentions' );
    unlike( $said, qr/\bbuglist\b/,
        'and a column the board marked as a queue is not among them' );
}

# --- proved by putting the old definition back -----------------------------------

{
    no warnings 'redefine';
    local *Tira::_queue_columns = sub {
        my ( $self, $where, $type ) = @_;
        my $ends = $self->_ending_columns( $where, $type );
        my $columns = eval { $self->column_list( project => $where, type => $type ) } || [];
        return { map { $_->{name} => 1 }
              grep { $_->{protected} && !$ends->{ $_->{name} } } @{$columns} };
    };

    is_deeply( $tira->work_order( project => $root ), [],
        'protected-and-not-an-ending offers nothing again, which is the board they reported' );
}

done_testing;

__END__

=head1 NAME

259-a-queue-a-board-names-itself.t - which columns work waits in, said by the board

=head1 DESCRIPTION

C<protected> means Tira owns a column, and it was doing duty as a statement
about what a column MEANS. On a board that queues work in columns it created,
every waiting card was invisible to C<work_order> by construction - so
C<tira.next> answered empty and C<priority-skipped> could not fire at all.

C<tira.column.update --queue> lets a board say which of its columns work waits
in. A board that says nothing keeps the old assumption exactly.

=cut
