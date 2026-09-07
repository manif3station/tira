#!/usr/bin/env perl
# TKT-987, found while measuring TKT-979 - itself from his Telegram request to
# reduce police's resource use.
#
# MEASURED on all three of his boards at /tmp/testing, via a wrapped
# history_list counting calls for a ref already read earlier in the same
# pass: budget 24 calls/0 repeats, developer-dashboard 225/80 (36%), zenandi
# 765/416 (54%) - matching the original "416 of 765" finding exactly.
#
# WHERE THE 416 CAME FROM, read in the source rather than guessed. Four
# independent call sites each open and JSON-decode a card's whole journal:
# _policy_last_detail_change (115 calls on zenandi), _police_history, called
# from three separate rule blocks (77), _card_last_author (39), and
# policy_evaluate's own discard-unexplained loop, which reads every
# discarded record's column-field history directly (184, one per discarded
# card on that board - and EVERY one of those 184 was already a repeat,
# meaning some earlier rule had opened that same journal first).
#
# TKT-978's path cache does not touch this: history_list calls _record_data
# to find the file (now cached), then opens and parses the file itself,
# every time, regardless of who is asking or whether anyone already asked.
#
# THE FIX is a per-pass cache at that shared parse, _journal_entries,
# holding the raw entries before any field/since/first/last filtering -
# filtering is cheap, the file read and per-line JSON decode is not. Scoped
# to _path_cache exactly like TKT-978's, for the same reason: police_pass
# never appends to a journal itself, so nothing invalidates a card's history
# mid-pass.
#
# THE REPAIR COUNT IS THE ONE SIDE EFFECT WORTH TESTING SEPARATELY.
# _police_history clears and re-reads $self->{_history_repaired}{$ref}
# around its own call, so a corrupted-byte report would go silently missing
# if some OTHER caller's read happened to be the one that actually touched
# the disk. The fix replays the repaired count into _history_repaired on a
# cache hit too, so this has to be asserted directly rather than inferred
# from a clean fixture that never repairs anything.
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

# Same reasoning as t/582: this file enables notify_moves and declares rules
# that call police_pass, which is the pair that can reach a real Telegram
# send. t/345 checks for exactly this.
delete local $ENV{TELEGRAM_BOT_TOKEN};
delete local $ENV{TELEGRAM_CHATID};

# Counts every journal LINE actually parsed, board-wide. Each fixture below
# gives every card exactly one journal line, so this number is exactly the
# count of REAL reads (cache misses) - a cache hit parses nothing, it clones
# what is already there.
my $lines_parsed = 0;
{
    no warnings 'redefine';
    my $orig = \&Tira::json_decode_repaired;
    *Tira::json_decode_repaired = sub {
        $lines_parsed++;
        return $orig->(@_);
    };
}

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $now  = '2026-09-07T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Read Once', dir => $root, members => ['claude'],
        columns    => ['backlog, working, discard'],
        sow_prefix => 'ROS', epic_prefix => 'ROE', ticket_prefix => 'ROT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ), \$now );
}

# --- the mechanism, isolated from any rule -----------------------------------
#
# Three independent readers of the SAME card's journal, called directly and
# in the order that makes the repair-count bug visible if it exists:
# something else reads first, then _police_history - the one caller whose
# own before/after delete of _history_repaired would otherwise lose it.

{
    my ( $tira, $root ) = board();
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card three rules ask about' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'working',
        author => 'claude' );

    $tira->_police_path_cache( sub {
        $lines_parsed = 0;

        # First reader: the same call policy_evaluate's discard-unexplained
        # loop makes directly, not through any of the three named subs.
        $tira->history_list( project => $root, ref => $card->{ref}, field => 'column' );
        my $after_first = $lines_parsed;

        # Second reader: a different caller, same ref.
        $tira->_policy_last_detail_change( project => $root, ref => $card->{ref} );
        my $after_second = $lines_parsed;

        # Third reader: _police_history, which clears and re-reads
        # _history_repaired{ref} around its own call - the one place a lost
        # repair count would show up.
        my $unreadable = [];
        $tira->_police_history( $root, $card->{ref}, $unreadable );
        my $after_third = $lines_parsed;

        cmp_ok( $after_first, '>', 0,
            'the first reader parses the journal, because nothing has read this card yet '
              . 'in this pass' );
        is( $after_second, $after_first,
            'the second reader, a different caller asking about the same card, parses '
              . 'nothing new - it gets what the first reader already found' );
        is( $after_third, $after_first,
            'and _police_history, reading third, also parses nothing new' );
        is_deeply( $unreadable, [], 'and nothing was reported unreadable for an intact card' );
    } );
}

# --- the repaired-byte count survives being read by someone else first ------
#
# The failure mode this test exists to catch: _police_history clears
# _history_repaired{ref} before calling history_list and reads it again
# after, to report corruption exactly once. If a DIFFERENT caller's read is
# the one that actually touches disk, the repair has to be replayed for
# _police_history to still see it.

{
    my ( $tira, $root ) = board();
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card with one damaged history byte' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'working',
        author => 'claude' );

    my $path = $tira->_journal_path( $root, $card->{ref} );
    open my $fh, '+<:raw', $path or die "test setup: $!";
    my $bytes = do { local $/; <$fh> };
    # Damage one byte of a UTF-8 multi-byte sequence in the author field,
    # the same class of corruption mt5-ai reported (TKT-... history repair).
    $bytes =~ s/"claude"/"cla\xFFde"/;
    seek $fh, 0, 0;
    print {$fh} $bytes;
    truncate $fh, length $bytes;
    close $fh;

    $tira->_police_path_cache( sub {

        # A different caller reads this ref FIRST - not _police_history.
        $tira->_card_last_author( $root, { ref => $card->{ref} } );

        my $unreadable = [];
        my $entries = $tira->_police_history( $root, $card->{ref}, $unreadable );

        ok( defined $entries, 'the card is still read, past the damaged byte' );
        is( scalar @{$unreadable}, 1,
            'and the repair is still reported by _police_history, even though a different '
              . 'caller read the same journal first this pass - the count has to be '
              . 'replayed on a cache hit, not just produced by whichever read happens to '
              . 'touch the disk' )
          or diag( 'unreadable: ' . ( @{$unreadable} ? $unreadable->[0]{reason} : '(empty)' ) );
    } );
}

# --- and a whole pass parses each card's journal once ------------------------
#
# discard-unexplained loops every discarded record directly, reading its
# column-field history straight from policy_evaluate; column-skipped reads
# the same journal via _police_history. Both are declared, so the same
# discarded cards are asked about twice by two independent rule blocks
# within one pass.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->policy_add( project => $root, rule => 'discard-unexplained', action => 'bridge-reminder' );
    $tira->policy_add( project => $root, rule => 'column-skipped', action => 'bridge-reminder',
        enter => 'discard', require => 'working' );

    my @refs;
    for my $i ( 1 .. 4 ) {
        my $card = $tira->create_record( project => $root, type => 'ticket',
            title => "a discarded card asked about twice ($i)" );
        push @refs, $card->{ref};
    }
    ${$clock} = '2026-09-07T09:30:00Z';
    $tira->record_move( project => $root, ref => $_, column => 'discard', author => 'claude' )
      for @refs;
    $tira->comment_add( project => $root, ref => $_, author => 'claude',
        text => 'discarding as a fixture card' )
      for @refs;

    ${$clock} = '2026-09-07T10:00:00Z';
    $lines_parsed = 0;
    my $result = $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
    ok( $result, 'the pass completes' );

    # Each card's journal has exactly 7 lines: 5 from creation (ref, type,
    # title, created_at, column), the move, and the comment - counted
    # directly rather than assumed. Four cards, read once each, is 28 lines
    # parsed - however many rule blocks ask about them.
    is( $lines_parsed, 28,
        'the whole board parses each of the 4 cards\' 7-line journals exactly once, not '
          . 'once per rule that asks about it' );
}

# --- nothing is remembered between passes ------------------------------------

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->policy_add( project => $root, rule => 'discard-unexplained', action => 'bridge-reminder' );
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'discarded once' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'discard', author => 'claude' );

    ${$clock} = '2026-09-07T10:00:00Z';
    $lines_parsed = 0;
    $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
    my $first_pass = $lines_parsed;
    cmp_ok( $first_pass, '>', 0, 'the first pass parses the journal' );

    ${$clock} = '2026-09-07T11:00:00Z';
    $lines_parsed = 0;
    $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
    is( $lines_parsed, $first_pass,
        'and a second, later pass parses it again from disk - the cache does not outlive '
          . 'the pass it belongs to' );
}

# --- the cache is scoped in the source, not left to a caller -----------------

{
    my $engine = Suite::engine_source();
    # non-empty is the whole claim: every check below would pass on an
    # unreadable file's emptiness alone.
    like( $engine, qr/\S/, 'the engine source is there to be read' );

    my ($sub) = $engine =~ /(sub \s+ _journal_entries \s* \{\n .*? \n\})/xs;
    like( $sub // '', qr/_path_cache/,
        '_journal_entries is found, and reads from _path_cache - the same per-pass scope '
          . 'TKT-978 already uses, asserted by content so a match on some other sub could '
          . 'not satisfy this' );
    like( $sub // '', qr/_history_repaired/,
        'and it replays the repaired-byte count on a cache hit, not just on a real read' );
}

done_testing();

__END__

=head1 NAME

587-a-journal-read-once-per-card.t - a police pass parses each card's journal once

=head1 DESCRIPTION

TKT-987. Four independent readers - C<_policy_last_detail_change>,
C<_police_history> (three call sites), C<_card_last_author>, and
C<policy_evaluate>'s own C<discard-unexplained> loop - each open and
JSON-decode a card's whole history journal, with no per-pass memory of what
was already read. Measured on his zenandi board: 765 C<history_list> calls,
416 of them (54%) asking about a ref some earlier rule in the same pass had
already read.

This holds the fix in place: C<_journal_entries> caches the raw parsed
entries for the life of one pass, so the whole board's journals are parsed
once each regardless of how many rules ask about them, while the
repaired-byte corruption count still reaches whichever caller checks for it
first - even when that caller is not the one whose read actually touched
disk.

=cut
