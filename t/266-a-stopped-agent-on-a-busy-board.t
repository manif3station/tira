#!/usr/bin/env perl
# The agent stopped and the board did not, so nothing said so.
#
# Measured on this board, and it is the reason the card exists: the agent's last
# action was 01:31 and its next was 07:27 - five hours fifty-six minutes -
# while board-still was declared at 4h and did not fire once. It reads the
# newest last_updated across every card, and seven cards arrived from other
# projects during the window. Each arrival refreshed that stamp. The board was
# busy; the agent was not.
#
# So the one rule whose whole job is "nothing is happening here" is blind to the
# case that actually happens on a board that receives reports from elsewhere. It
# measures the BOARD's pulse, and the thing that stops is the AGENT.
#
# card-still did report the two cards sitting in working columns, correctly, and
# escalated both to CRITICAL - addressed to the agent, who is by definition the
# party not listening.
#
# What this rule measures instead is agent action: a card changing column, or a
# card edited by the agent. A card arriving from somewhere else is neither.
#
# And it stays silent when nothing sits in a working column, because an idle
# queue is not a stopped agent. That distinction is not theoretical: an earlier
# 7h49m gap on this same board was investigated and found to be correct work
# throughout, so a rule that fired on elapsed time alone would have been wrong
# then and right now, which is no rule at all.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

# This file declares agent-still and calls police_pass() through reported()
# many times before the two blocks below that deliberately exercise the
# send path (and mock _post_telegram directly, which is why they are safe
# regardless of this). Every earlier call was unguarded: a host shell that
# happens to export real TELEGRAM_BOT_TOKEN/TELEGRAM_CHATID - as this
# project's own Telegram bridge does - sent a real message to the real
# owner every time this file ran outside Docker. t/345's own regression
# guard only checked whether the string TELEGRAM_BOT_TOKEN appeared
# anywhere in a file, not whether every police_pass call was actually
# guarded, so it missed this one. Confirmed live: repeated "the agent has
# stopped" messages naming this file's own STT fixture refs and its
# 2026-08-18T01:31:00Z/18:00:00Z timestamps. TKT-484.
delete local $ENV{TELEGRAM_BOT_TOKEN};
delete local $ENV{TELEGRAM_CHATID};

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-18T01:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Stopped', dir => $root, members => [ 'claude', 'michael' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'STS', epic_prefix => 'STE', ticket_prefix => 'STT',
);

# Which agent works this board is the fact the rule turns on, the same way
# card-changed-by-owner turns on it.
$tira->project_update( project => $root, agent => 'claude' );

sub reported {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'agent-still' } @{ $pass->{violations} } ];
}

# --- the rule exists ------------------------------------------------------------

{
    my %rules = map { $_ => 1 } @{ Tira::policy_rules() };
    ok( $rules{'agent-still'}, 'the catalogue offers a rule for a stopped agent' );
}

# --- and it will not be declared without an age ----------------------------------
#
# How long an agent may go without acting is a decision about how it works, the
# same judgement board-still and bridge-unread refuse to guess at.

{
    my $bare = eval {
        $tira->policy_add( project => $root, rule => 'agent-still',
            action => 'bridge-reminder' );
        1;
    };
    ok( !$bare, 'declaring it without an age is refused' );
    like( $@ // '', qr/--age/, 'and the refusal names the option' );
}

$tira->policy_add( project => $root, rule => 'agent-still', age => '4h',
    action => 'bridge-reminder' );

# --- an agent that is working is not reported -------------------------------------
#
# Asserted before the stoppage, so what follows is a rule that fires on silence
# rather than one that fires on everything.

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Being worked', priority => 5, assignee => 'claude' );
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );

{
    $now = '2026-08-18T01:31:00Z';
    $tira->record_update( project => $root, ref => $card->{ref}, author => 'claude',
        solution_needed => 'Working on it.' );

    is_deeply( reported(), [], 'an agent that has just acted is not reported' );
}

# --- the stoppage, with the board busy the whole time -----------------------------
#
# The measured case. Six hours pass. The agent does nothing. Seven cards arrive
# from other projects, exactly as TKT-352 through TKT-358 did, and every one of
# them refreshes the newest last_updated on the board.

{
    $now = '2026-08-18T04:00:00Z';
    for my $n ( 1 .. 7 ) {
        $tira->create_record( project => $root, type => 'ticket',
            title => "Filed by another project, number $n", priority => 3,
            author => 'zenandi' );
    }

    $now = '2026-08-18T07:27:00Z';

    # First, the fact that makes this card necessary: the board looks busy.
    my ($newest) = sort { $b cmp $a } grep { defined }
      map  { $_->{last_updated} }
      @{ $tira->record_list( project => $root, type => 'ticket' ) };
    is( $newest, '2026-08-18T04:00:00Z',
        'the newest stamp on the board is an arrival from elsewhere, not the agent' );

    my $found = reported();
    is( scalar @{$found}, 1, 'and the agent is reported as stopped anyway' );
    like( $found->[0]{detail} // '', qr/5h|6h/,
        'naming how long it has been since the agent acted, not since the board changed' );
    like( $found->[0]{detail} // '', qr/\Q$card->{ref}\E/,
        'and which card is sitting while it waits' );
}

# --- an idle queue is not a stopped agent ------------------------------------------
#
# The half that keeps this from being a clock. An earlier 7h49m gap on this
# board was investigated and found to be correct work throughout - there was
# simply nothing in a working column. A rule that reported that would be crying
# wolf on the one board that had done nothing wrong.

{
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'done' );
    $now = '2026-08-18T18:00:00Z';

    is_deeply( reported(), [],
        'with nothing left in a working column, a long silence is not reported' );
}

# --- and a card the agent moves settles it ------------------------------------------
#
# Compared rather than remembered, like every other rule here: the agent's own
# action becomes the newest one.

{
    my $fresh = $tira->create_record( project => $root, type => 'ticket',
        title => 'Picked up again', priority => 4, assignee => 'claude' );
    $tira->record_move(author => 'claude',  project => $root, ref => $fresh->{ref}, column => 'implement' );

    $now = '2026-08-19T00:00:00Z';
    my $stopped = reported();
    is( scalar @{$stopped}, 1, 'six hours after that move it is reported again' );

    $now = '2026-08-19T00:01:00Z';
    $tira->record_move(author => 'claude',  project => $root, ref => $fresh->{ref}, column => 'done' );
    $tira->create_record( project => $root, type => 'ticket',
        title => 'Still something to do', priority => 4, assignee => 'claude' );
    my $after = $tira->create_record( project => $root, type => 'ticket',
        title => 'And it is being worked', priority => 4, assignee => 'claude' );
    $tira->record_move(author => 'claude',  project => $root, ref => $after->{ref}, column => 'implement' );

    is_deeply( reported(), [],
        'and the agent moving a card settles it, with nothing to remember' );
}

# --- and it reaches somebody who is not the agent ------------------------------------
#
# The half without which the rule is useless. card-still reported both stranded
# cards during the real stoppage and escalated them to CRITICAL, addressed to
# the agent - the one party guaranteed not to be reading, because it had
# stopped. A finding about a stopped agent has to leave the machine.
#
# It goes out the way TKT-349's notifier does, through the same seam and the
# same two variables, so there is one way this board speaks to him.

{
    $now = '2026-08-19T18:00:00Z';
    my @sent;
    my $pass = do {
        no warnings 'redefine';
        local *Tira::_post_telegram = sub {
            my ( $self, $token, $chat, $text ) = @_;
            push @sent, $text;
            return 1;
        };
        local $ENV{TELEGRAM_BOT_TOKEN} = 'T';
        local $ENV{TELEGRAM_CHATID}    = 'C';
        $tira->police_pass( project => $root, store => $store, world => {} );
    };

    cmp_ok( scalar @sent, '>', 0, 'a stopped agent is told to somebody off the board' );
    like( join( '', @sent ), qr/agent/i, 'and the message says what has stopped' );
}

# --- but only when the board asked to be told ------------------------------------------
#
# Opt-in, like the notifier it borrows. A board that has not set the variables
# is not silently reaching out to an address nobody configured.

{
    $now = '2026-08-20T06:00:00Z';
    my @sent;
    {
        no warnings 'redefine';
        local *Tira::_post_telegram = sub { push @sent, $_[3]; return 1 };
        delete local $ENV{TELEGRAM_BOT_TOKEN};
        delete local $ENV{TELEGRAM_CHATID};
        $tira->police_pass( project => $root, store => $store, world => {} );
    }
    is_deeply( \@sent, [], 'with no address configured, nothing is sent' );
}

# --- proved by measuring the board instead of the agent ------------------------------
#
# Without the distinction this rule is board-still under another name, and the
# stoppage it was written for goes unreported exactly as it did.

{
    $now = '2026-08-19T09:00:00Z';
    cmp_ok( scalar @{ reported() }, '>', 0, 'the stopped agent is reported' );

    no warnings 'redefine';
    local *Tira::_agent_last_acted = sub {
        my ( $self, $root, $all ) = @_;
        my ($newest) = sort { $b cmp $a } grep { defined }
          map { $_->{last_updated} } @{$all};
        return $newest;
    };

    # An arrival from another project, at this instant, exactly as happened.
    $tira->create_record( project => $root, type => 'ticket',
        title => 'Another project files one more', priority => 3, author => 'zenandi' );

    is_deeply( reported(), [],
        'and reading the board rather than the agent reports nothing, which is what happened' );
}

done_testing;

__END__

=head1 NAME

266-a-stopped-agent-on-a-busy-board.t - the stoppage board-still could not see

=head1 DESCRIPTION

C<board-still> reads the newest C<last_updated> across every card, so a board
that receives reports from other projects always looks busy. Measured here: the
agent stopped for five hours fifty-six minutes while seven cards arrived from
elsewhere, and the rule declared at 4h never fired.

C<agent-still> measures agent action instead - a card changing column, or a card
the agent edited. It stays silent when nothing sits in a working column, because
an idle queue is not a stopped agent.

=cut
