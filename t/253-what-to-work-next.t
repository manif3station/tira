#!/usr/bin/env perl
# The board answers what to work next, because it already decided.
#
# priority-skipped reports work taken out of turn. To do that it must already
# know which cards are waiting - in a column the board protects, not an ending,
# carrying a priority - and which of them outranks which, 5 being the urgent
# end. That decision has been in the engine since the rule was written.
#
# No command asked it. A caller wanting to know what to pick up ran
# tira.ticket.list and got every card on the board - 1.95 MB of JSON for 292
# cards to find the 11 that were waiting - and then sorted by priority and age
# themselves. This project did exactly that, by hand, with the same snippet,
# every time it picked up a card.
#
# The risk worth avoiding is the one this board keeps finding: a second copy of
# the ordering that can disagree with the rule about the same board. So the rule
# and the command ask the same method, and this asserts they agree.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-17T09:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Ordered', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ODS', epic_prefix => 'ODE', ticket_prefix => 'ODT',
);

# Raised oldest first, so age is a real tie-breaker rather than an accident of
# the order they happen to be read in.
my $old_middle = $tira->create_record( project => $root, type => 'ticket',
    title => 'Middling, and waiting longest', priority => 3 );
$now = '2026-08-17T10:00:00Z';
my $urgent = $tira->create_record( project => $root, type => 'ticket',
    title => 'The urgent one', priority => 5 );
$now = '2026-08-17T11:00:00Z';
my $new_middle = $tira->create_record( project => $root, type => 'ticket',
    title => 'Middling, and newer', priority => 3 );
$now = '2026-08-17T12:00:00Z';
my $being_worked = $tira->create_record( project => $root, type => 'ticket',
    title => 'Already in hand', priority => 4 );
$tira->record_move(author => 'claude',  project => $root, ref => $being_worked->{ref}, column => 'implement' );
my $unprioritised = $tira->create_record( project => $root, type => 'ticket',
    title => 'Nobody has said how urgent this is' );

sub run {
    my @argv = @_;
    my $where = ( @argv && $argv[-1] =~ m{/} ) ? pop @argv : $root;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $where;
            Tira::CLI->run( command => 'next', tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# --- the order the board would enforce -----------------------------------------

my $order = $tira->work_order( project => $root );

isa_ok( $order, 'ARRAY', 'the board answers with a list' );
cmp_ok( scalar @{$order}, '>', 0, 'and there is work waiting on it' );

is( $order->[0]{ref}, $urgent->{ref},
    'the most urgent card waiting is the answer to what to work next' );

is_deeply( [ map { $_->{ref} } @{$order} ],
    [ $urgent->{ref}, $old_middle->{ref}, $new_middle->{ref} ],
    'then priority, then the one that has waited longest' );

# --- what is not on it ----------------------------------------------------------
#
# A card somebody is working is not waiting, and a card nobody has prioritised
# cannot be placed - the rule that owns this decision says nothing about either.

{
    my %listed = map { $_->{ref} => 1 } @{$order};
    ok( !$listed{ $being_worked->{ref} },  'a card already being worked is not offered' );
    ok( !$listed{ $unprioritised->{ref} }, 'nor one nobody has given a priority' );
}

# --- and it agrees with the rule that enforces it -------------------------------
#
# The whole point. If these two can disagree about the same board, the command
# is a second opinion rather than an answer.

{
    $tira->policy_add( project => $root, rule => 'priority-skipped',
        action => 'bridge-reminder' );

    # Work the wrong one: the newer middling card while the urgent one waits.
    $tira->record_move(author => 'claude',  project => $root, ref => $new_middle->{ref}, column => 'implement' );

    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    my @skipped = grep { ( $_->{rule} // '' ) eq 'priority-skipped' }
      @{ $pass->{violations} };

    ok( scalar @skipped, 'working out of turn is reported' );
    like( $skipped[0]{detail} // '', qr/\Q$urgent->{ref}\E/,
        'naming the card that was passed over' );
    is( $tira->work_order( project => $root )->[0]{ref}, $urgent->{ref},
        'which is the same card the board would have offered' );

    # Every card the rule says was passed over has to be a card the command
    # offers. Checking the one card is not enough - it passes just as well
    # against a rule with a looser idea of which cards are waiting, which is
    # exactly the second copy this card exists to prevent. Found by breaking
    # it: the rule was handed its own list again and the one-card assertion
    # never noticed.
    my %offered = map { $_->{ref} => 1 }
      @{ $tira->work_order( project => $root ) };
    my @passed_over = grep { !$offered{$_} }
      map { /(\b[A-Z]+-\d+)\b/ ? $1 : () } map { $_->{detail} // '' } @skipped;

    is_deeply( \@passed_over, [],
        'and every card it says was passed over is one the command offers, '
          . 'so the two share a definition of waiting rather than agreeing by luck' );
}

# --- a board where a second copy would say something different ------------------
#
# The assertion above passes against a rule with a looser idea of which cards
# are waiting, because on that board the loose answer and the right one happen
# to name the same card. Found by breaking it, not by reading it.
#
# So: a board whose only high-priority card is one somebody is already working.
# Nothing is waiting, so nothing was passed over. A rule counting every
# prioritised card as waiting reports the card in hand as though it were queued,
# and names a card the command does not offer - which is what two definitions of
# waiting looks like from the outside.

{
    my $two = File::Spec->catdir( $tmp, 'diverge' );
    $tira->project_new(
        name => 'Diverge', dir => $two, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'DVS', epic_prefix => 'DVE', ticket_prefix => 'DVT',
    );
    $tira->policy_add( project => $two, rule => 'priority-skipped',
        action => 'bridge-reminder' );

    for my $card ( [ 'The urgent one, in hand', 5 ], [ 'The lesser one, also in hand', 2 ] ) {
        my $made = $tira->create_record( project => $two, type => 'ticket',
            title => $card->[0], priority => $card->[1] );
        $tira->record_move(author => 'claude',  project => $two, ref => $made->{ref}, column => 'implement' );
    }

    is_deeply( $tira->work_order( project => $two ), [],
        'with both cards in hand there is nothing waiting to offer' );

    my $pass = $tira->police_pass( project => $two,
        store => File::Spec->catdir( $tmp, 'police-two' ), world => {} );
    my @skipped = grep { ( $_->{rule} // '' ) eq 'priority-skipped' }
      @{ $pass->{violations} };

    is_deeply( [ map { $_->{detail} } @skipped ], [],
        'and nothing was passed over, because nothing was waiting to be passed' );
}

# --- and the command says it ----------------------------------------------------
#
# The answer, and what it was chosen over. A caller who is only told the answer
# has to trust it; one who is told what it beat can check it.

{
    my ( $status, $said ) = run('-o','json');
    is( $status, 0, 'the command answers' );
    like( $said, qr/\Q$urgent->{ref}\E/, 'naming the card to work next' );
    my $answer = Tira::json_decode($said);
    is( $answer->{next}{ref}, $urgent->{ref}, 'as the answer' );
    is( scalar @{ $answer->{then} }, 1,
        'with what it was chosen over, so the answer can be checked' );
}

# --- and on a board with nothing waiting ----------------------------------------
#
# No answer is an answer. An empty list rather than a card the caller would then
# work, which is the failure mode worth avoiding here.

{
    my $empty = File::Spec->catdir( $tmp, 'empty' );
    $tira->project_new(
        name => 'Empty', dir => $empty, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'MTS', epic_prefix => 'MTE', ticket_prefix => 'MTT',
    );

    my ( $status, $said ) = run( '-o', 'json', $empty );
    is( $status, 0, 'a board with nothing waiting still answers' );

    # Until TKT-354, this answered with a bare [] - a different TYPE than
    # the {next,then} hash a busy board answers with, so a caller doing
    # result->{next} worked every time there was work and crashed the
    # first time the board went quiet. Now a hash in both states: next is
    # undef rather than a card, then is an empty array either way.
    is_deeply( Tira::json_decode($said), { next => undef, then => [] },
        'with next undef and then empty, rather than a card there is no reason to work, and rather than a different type entirely' );
}

# --- proved by changing what outranks what --------------------------------------
#
# Nothing about the cards changes except a number, and the answer has to follow
# it - otherwise the order is coming from somewhere other than the priority.

{
    $tira->record_update( author => 'claude', project => $root, ref => $old_middle->{ref}, priority => 5 );
    $tira->record_update( author => 'claude', project => $root, ref => $urgent->{ref}, priority => 1 );

    my $reordered = $tira->work_order( project => $root );
    is( $reordered->[0]{ref}, $old_middle->{ref},
        'raising a card above the rest makes it the next one' );
    is( $reordered->[-1]{ref}, $urgent->{ref},
        'and lowering the old answer sends it to the end' );
}

done_testing;

__END__

=head1 NAME

253-what-to-work-next.t - the order the board already decided, said out loud

=head1 DESCRIPTION

C<priority-skipped> has always known which cards are waiting and which outranks
which; no command asked it, so a caller read every card on the board and sorted
them by hand - 1.95 MB of JSON to answer a one-line question.

C<work_order> is that decision, asked by the rule and by the command, so the two
cannot give different answers about the same board.

=cut
