#!/usr/bin/env perl
# TKT-979, found while measuring TKT-978 on his behalf: "find out what is
# causing the police taking so much resource and find a way to make the
# police run more efficent and less resource".
#
# _announce_moves calls _last_move for EVERY record on the board (lib/Tira.pm,
# including discards, and _last_move opens the card's entire journal through
# history_list to find its newest column-move entry - THEN, only after that
# read, _notified_move_at is consulted to ask whether this move was already
# announced. Re-profiled on his zenandi copy with TKT-978's fix already in
# place: _announce_moves is on the stack for 61.9% of a pass, because on a
# mature board almost every card is quiet and every one of them still pays for
# a full journal read.
#
# THE ANSWER IS ALREADY THERE, ASKED IN THE WRONG ORDER. A card's newest
# history entry cannot be later than its own last_updated - the same fact the
# agent-still rule already uses in this file, in its own words: "a card
# already older than the best answer so far cannot improve on it and its
# history never has to be opened." _notified_move_at holds the timestamp of
# the last move this board already announced for a ref. If a record's
# last_updated is no newer than that stamp, its journal cannot contain a move
# later than what was already said, and reading it teaches nothing.
#
# WHAT MUST NOT BREAK. A card is still announced exactly when it always was:
# _last_move's own filter (field column, op move) still decides what counts as
# a move, so the skip changes WHEN the journal is opened, never WHAT the
# comparison decides. Two edge cases from reading _announce_moves itself:
#   - include_discard => 1 means discarded cards are in @{$records} too, and a
#     discarded card is exactly the kind that is old, long and permanently
#     quiet - the case this card is FOR.
#   - a record with no last_updated must not be treated as quiet, the same
#     "unknown is not evidence" reasoning priority-skipped already gives for
#     an unknown age.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;
use Tira::CLI::Police;

# This file declares notify_moves enabled, which can reach a real Telegram
# send through police_pass - it has done so to his real phone before (TKT-482,
# TKT-484), and t/345 refuses any file that reaches police_pass before
# neutralising the environment. Cleared before the first call in the file.
delete local $ENV{TELEGRAM_BOT_TOKEN};
delete local $ENV{TELEGRAM_CHATID};

# Counted by wrapping history_list, the sub the walk actually goes through -
# not _last_move, which would hide a caller that read the journal some other
# way, and not a mock of the journal file, which the engine never touches
# directly from this rule.
my %reads;
my $reads_total = 0;
{
    no warnings 'redefine';
    my $orig = \&Tira::history_list;
    *Tira::history_list = sub {
        my ( $self, %args ) = @_;
        $reads_total++;
        $reads{ $args{ref} // '?' }++;
        return $orig->( $self, %args );
    };

    # A move is only remembered as announced once it was actually TOLD - by
    # design, so configuring the variables later cannot lose a move nobody
    # heard. With TELEGRAM_BOT_TOKEN cleared above, _send_notification would
    # otherwise fail every time and the notified-move stamp this whole card
    # depends on would never be written, making the skip untestable rather
    # than untrue. Mocked the same way t/365 and t/294 already do.
    *Tira::_send_notification = sub { return 1 };
}

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $now  = '2026-09-06T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Quiet Cards', dir => $root, members => ['claude'],
        columns    => ['backlog, implement, done'],
        sow_prefix => 'QCS', epic_prefix => 'QCE', ticket_prefix => 'QCT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    $tira->notify_moves( project => $root, enabled => 1 );
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ), \$now );
}

sub run_pass {
    my ( $tira, $root, $store ) = @_;
    %reads       = ();
    $reads_total = 0;
    return $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
}

# --- a card already announced is not re-read ---------------------------------
#
# The whole card. A pass sees the same board twice: the first pass announces
# the move and stamps it, and the second must not open that card's journal
# again to reach the same conclusion.

{
    my ( $tira, $root, $store, $clock ) = board();
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card that moves once and then sits still' );

    ${$clock} = '2026-09-06T09:30:00Z';
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement',
        author => 'claude' );

    ${$clock} = '2026-09-06T10:00:00Z';
    my $first = run_pass( $tira, $root, $store );
    ok( ( grep { $_ eq $card->{ref} } @{ $first->{announced} || [] } ) ||
          $reads{ $card->{ref} },
        'the first pass opens the journal and announces the move - establishing '
          . 'that this fixture actually reaches the card, so the second pass '
          . 'skipping it means something' );

    ${$clock} = '2026-09-06T10:05:00Z';
    run_pass( $tira, $root, $store );
    is( $reads{ $card->{ref} }, undef,
        'and the SECOND pass never opens that journal at all - the ledger already '
          . 'holds the answer, and last_updated has not moved past it since' )
      or diag("history_list was called for $card->{ref} on the quiet pass");
}

# --- a card that moves again is still caught ---------------------------------
#
# The direction a careless skip breaks. A card can move a second time after
# being announced once, and that move must still be seen and said.

{
    my ( $tira, $root, $store, $clock ) = board();
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card that moves twice' );

    ${$clock} = '2026-09-06T09:30:00Z';
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement',
        author => 'claude' );
    ${$clock} = '2026-09-06T10:00:00Z';
    run_pass( $tira, $root, $store );

    ${$clock} = '2026-09-06T10:30:00Z';
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'done',
        author => 'claude' );
    ${$clock} = '2026-09-06T11:00:00Z';
    run_pass( $tira, $root, $store );

    is( $reads{ $card->{ref} }, 1,
        'the pass after the SECOND move opens the journal exactly once - the skip '
          . "only applies while nothing has changed since the card's own stamp" );
}

# --- a discarded card is skipped too -------------------------------------------
#
# _announce_moves lists with include_discard => 1 specifically, and a
# discarded card is the commonest kind of old-and-quiet - the case this whole
# fix is for.

{
    my ( $tira, $root, $store, $clock ) = board();
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card that is discarded and then left alone' );

    ${$clock} = '2026-09-06T09:30:00Z';
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'discard',
        author => 'claude', reason => 'no longer needed' );
    ${$clock} = '2026-09-06T10:00:00Z';
    run_pass( $tira, $root, $store );

    ${$clock} = '2026-09-06T10:05:00Z';
    run_pass( $tira, $root, $store );
    is( $reads{ $card->{ref} }, undef,
        'a discarded card that has not changed since it was announced is skipped '
          . 'too, because _announce_moves reads discards deliberately (TKT-349) and '
          . 'a discard is exactly the old, long, permanently-quiet case' );
}

# --- a card with no last_updated is never assumed quiet -----------------------
#
# "Unknown is not evidence" - the same reasoning priority-skipped already
# gives for an age that cannot be read. Skipping on an absent last_updated
# would be optimising by guessing, and a guess that is wrong is silent.

{
    my ( $tira, $root, $store, $clock ) = board();
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card with no last_updated' );
    ${$clock} = '2026-09-06T09:30:00Z';
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement',
        author => 'claude' );
    ${$clock} = '2026-09-06T10:00:00Z';
    run_pass( $tira, $root, $store );

    # Strip last_updated from the stored record directly, simulating a record
    # this rule cannot date - the only way to reach that state without the
    # engine itself refusing to write one.
    my ($path) = $tira->_record_data( project => $root, ref => $card->{ref} );
    my $data = $tira->_read_json($path);
    delete $data->{last_updated};
    $tira->_write_json( $path, $data );

    ${$clock} = '2026-09-06T10:05:00Z';
    run_pass( $tira, $root, $store );
    is( $reads{ $card->{ref} }, 1,
        'a card with no last_updated has its journal read rather than being assumed '
          . 'quiet - an unknown date is not evidence that nothing changed' );
}

# --- the skip is read from the source, not inferred from behaviour ------------
#
# What the behaviour above cannot show: that the comparison is against the
# ledger's OWN stamp for THIS ref, not some other proxy that would happen to
# agree on these fixtures.

{
    my $engine = Suite::engine_source();
    # non-empty is the whole claim: every check below would pass on an
    # unreadable file's emptiness alone.
    like( $engine, qr/\S/, 'the engine source is there to be read' );

    my ($sub) = $engine =~ /(sub\s+_announce_moves\s*\{\n.*?\n\})/s;
    like( $sub // '', qr/notified_moves/,
        '_announce_moves was found, and is the one that touches the notified-move '
          . 'ledger - asserted by content so a match on the wrong sub could not '
          . 'satisfy the check below' );

    my $notified_at = index( $sub // '', '_notified_move_at' );
    my $last_move_at = index( $sub // '', '_last_move(' );
    cmp_ok( $notified_at, '>', -1, 'it consults the notified-move stamp' );
    cmp_ok( $last_move_at, '>', -1, 'and it calls _last_move' );
    cmp_ok( $notified_at, '<', $last_move_at,
        'and the stamp is read BEFORE _last_move opens the journal - which is the '
          . 'whole fix, since both calls already existed and only their order was '
          . 'wrong' );
}

done_testing();

__END__

=head1 NAME

585-a-question-asked-after-its-own-answer.t - a quiet card's journal is not reopened every pass

=head1 DESCRIPTION

TKT-979. C<_announce_moves> calls C<_last_move> for every record on the board,
which opens the card's entire journal through C<history_list> to find its
newest column-move entry - and only afterwards asks C<_notified_move_at>
whether that move was already announced. On his zenandi copy, re-profiled
after TKT-978's fix, this rule is on the stack for 61.9% of a pass, because
almost every card is quiet and every one of them still pays for a full journal
read to learn what the ledger already knew.

This holds the fix: a card whose C<last_updated> is no newer than its own
notified-move stamp has its journal skipped entirely, a card that moves again
is still caught, a discarded card - the commonest old-and-quiet case, since
C<_announce_moves> reads discards deliberately - is skipped too, and a card
with no C<last_updated> is never assumed quiet, since an unknown date is not
evidence that nothing changed.

=cut
