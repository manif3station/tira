#!/usr/bin/env perl
# TKT-978, from his request on 2026-09-06: "find out what is causing the police
# taking so much resource and find a way to make the police run more efficent
# and less resource". Measured inside tira:latest against the three board
# copies he left at /tmp/testing.
#
# WHAT IS ACTUALLY EXPENSIVE, and it is not the rules. A sampling profile of
# one pass on his zenandi copy (1,094 samples at 20ms) put policy_evaluate at
# 0.5% and file reading at the top: _slurp 21.2%, _record_data 16.5%,
# history_list 7.6%, project_show 7.4%.
#
# THE CAUSE, read in the source rather than inferred. lib/Tira.pm, _record_data
# locates a card by running File::Find over all three board trees and matching
# "$ref.json" by basename - every call. A card's path is fully determined by
# its ref, so the walk rediscovers what the ref already says. history_list
# calls _record_data before reading a journal, so every history read pays for a
# walk too.
#
# COUNTED over one zenandi pass: 765 _record_data calls and 765 history_list
# calls against 349 cards, 3,403 file reads in all. Timed directly, one walk is
# 0.0095s while reading and parsing the card it finds is 0.0002s - the walk is
# 75% of a lookup and the read is 1%. At ~1,384 lookups a pass that is 10.6s of
# a 14.11s pass.
#
# SO THE FIX IS THE PATH, NOT THE RECORD. Caching resolved paths for the life
# of one pass captures the whole win while every read still re-reads the file
# from disk. That distinction is not tidiness: police_pass calls
# _raise_upgrade_gate, which CREATES a card while the pass is running, so a
# cached parsed record could go stale mid-pass - but a cached path cannot,
# because writing a card does not move its file. A resolution that FAILS must
# not be cached either, for the same reason.
#
# THE ASSERTION IS EXACT RATHER THAN A THRESHOLD. "No ref is walked for twice
# within one pass" needs no invented number, and it is the property that makes
# the cost follow the board instead of the question count.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Find ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;
use Tira::CLI::Police;

# This file declares agent-still AND enables notify_moves, which is exactly the
# pair that can reach a real Telegram send through police_pass. A host shell
# exporting real TELEGRAM_BOT_TOKEN/TELEGRAM_CHATID - as this project's own
# bridge does - would message the owner for every fixture card. t/345 caught
# this file the moment it was written, which is what that guard exists for.
# TKT-482, TKT-484.
delete local $ENV{TELEGRAM_BOT_TOKEN};
delete local $ENV{TELEGRAM_CHATID};

# Every board walk, attributed to the ref being resolved. _record_data runs
# find() once per board tree, so an uncached lookup shows as three walks and a
# cached one as none.
# A package global rather than a lexical, because the wrapper localises it and
# `local` cannot take a lexical - it restores on the way out of a lookup even
# when the lookup dies, which the "card that does not exist" case relies on.
our $current_ref;
my %walks;      # ref -> board walks charged to it
my %lookups;    # ref -> times the pass asked where it is
my $walks_total = 0;

# LOOKUPS AND WALKS ARE COUNTED SEPARATELY, and the difference is the whole
# point: today they move together, and the fix makes the second stop growing
# while the first does not. Counting only walks would let a fixture that never
# repeats a lookup report success for the wrong reason.
{
    no warnings 'redefine';

    # Tira::find, NOT File::Find::find. lib/Tira.pm line 12 says
    # `use File::Find qw(find)`, so the engine holds its own alias, taken at
    # import time - overriding the original afterwards leaves that alias
    # untouched and the counter reads zero for a pass that walked the board
    # seven times. The first working version of this test reported exactly
    # that: "lookups 7 over 6 cards; walks 0", and a uniform zero is an
    # instrument that never ran, not a board that never walked.
    my $find = \&Tira::find;
    *Tira::find = sub {
        $walks_total++;
        $walks{ $current_ref // '?' }++ if defined $current_ref;
        return $find->(@_);
    };

    my $record_data = \&Tira::_record_data;
    *Tira::_record_data = sub {
        my ( $self, %args ) = @_;
        local $current_ref = $args{ref} // '?';
        $walks{$current_ref}   += 0;
        $lookups{$current_ref} += 1;
        return $record_data->( $self, %args );
    };
}

sub board {
    my (%opt) = @_;
    my $tmp  = tempdir( CLEANUP => 1 );
    my $now  = $opt{now} // '2026-09-06T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Walked Once', dir => $root, members => ['claude'],
        columns    => ['backlog, implement, done'],
        sow_prefix => 'WOS', epic_prefix => 'WOE', ticket_prefix => 'WOT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ), \$now );
}

sub run_pass {
    my ( $tira, $root, $store ) = @_;
    %walks       = ();
    %lookups     = ();
    $walks_total = 0;
    my $result = $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
    return $result;
}

# --- a pass resolves each card's location once ------------------------------
#
# The whole card. The board is set up so the pass asks about the same cards
# repeatedly: several rules over several cards, each of which reaches for the
# record and its history.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->policy_add( project => $root, rule => 'orphan-card',  action => 'bridge-reminder' );
    $tira->policy_add( project => $root, rule => 'card-duration', action => 'bridge-reminder',
        age => '10m', column => 'backlog' );
    $tira->policy_add( project => $root, rule => 'agent-still', action => 'bridge-reminder',
        age => '10m' );

    # MOVE ANNOUNCEMENTS ARE WHY A PASS READS HISTORIES AT ALL, and they are
    # off until somebody turns them on. The first version of this test declared
    # three rules, left this off, and the pass never looked a single card up -
    # so "no card was walked for twice" went GREEN against the unfixed code on
    # an empty count. The check above it is what caught that, and it is why the
    # count is asserted rather than the structure.
    # TWO CALLS, NOT ONE. The column branch and the enabled branch are
    # exclusive in notify_moves, so passing both in a single call sets the
    # column's flag and leaves the master switch off - which is exactly what
    # the second draft of this test did, and the pass then opened one history
    # instead of six.
    $tira->notify_moves( project => $root, enabled => 1 );
    $tira->notify_moves( project => $root, enabled => 1, column => 'implement' );

    my @refs;
    for my $i ( 1 .. 6 ) {
        my $card = $tira->create_record( project => $root, type => 'ticket',
            title => "a card the rules will ask about ($i)" );
        push @refs, $card->{ref};
    }

    # A move gives each card a history worth reading, which is what _last_move
    # opens for every record on the board, once per pass, through history_list.
    ${$clock} = '2026-09-06T09:30:00Z';
    $tira->record_move( project => $root, ref => $_, column => 'implement',
        author => 'claude' )
      for @refs;

    ${$clock} = '2026-09-06T10:00:00Z';
    run_pass( $tira, $root, $store );

    my @twice    = grep { $walks{$_} > 3 } keys %walks;
    my @repeated = grep { $lookups{$_} > 1 } keys %lookups;
    my $total    = 0;
    $total += $lookups{$_} for keys %lookups;

    diag( sprintf 'lookups %d over %d cards; walks %d', $total, scalar keys %lookups,
        $walks_total );

    cmp_ok( scalar keys %lookups, '>=', 2,
        'the pass asked for more than one card by ref, so there is something to count - '
          . 'asserted by the count rather than by the structure being non-empty, since an '
          . 'instrument that captured nothing would otherwise report a clean board' );

    cmp_ok( scalar @repeated, '>=', 1,
        'and at least one card was asked for TWICE, which is the thing this card is about - '
          . 'a fixture where every ref is asked for once would satisfy the claim below '
          . 'without exercising it, which is how the first draft of this test went green '
          . 'against the unfixed code' )
      or diag( "lookups: " . join( ', ', map { "$_ => $lookups{$_}" } sort keys %lookups ) );

    is_deeply( \@twice, [],
        'and NO card was walked for twice in the pass - each ref resolves to a path once, '
          . 'because a walk costs 0.0095s and the read it enables costs 0.0002s' )
      or diag( "walked more than once: "
          . join( ', ', map { "$_ => $walks{$_}" } sort @twice ) );
}

# --- and asking twice for the same card walks once ---------------------------
#
# The mechanism, isolated from the rules. Two identical lookups inside one pass
# is the case the cache exists for, and it is asserted directly so a change in
# which rules run cannot make the test above vacuous.

{
    my ( $tira, $root, $store ) = board();
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card asked for twice' );

    $tira->_police_path_cache( sub {
        %walks       = ();
        $walks_total = 0;
        $tira->_record_data( project => $root, ref => $card->{ref} );
        my $first = $walks_total;
        $tira->_record_data( project => $root, ref => $card->{ref} );
        my $second = $walks_total - $first;

        cmp_ok( $first, '>', 0, 'the first lookup walks the board, because nothing has told '
              . 'it where the card is yet' );
        is( $second, 0,
            'and the second walks not at all - the path a ref resolves to cannot change '
              . 'while a pass runs' );
    } );
}

# --- nothing is remembered between passes ------------------------------------
#
# The direction this breaks if the cache outlives its pass: a board is a live
# thing, and a card created after a pass must be visible to the next one. The
# same object is reused deliberately, since a fresh object would pass whether
# or not the cache is scoped.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );
    my $first = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card that exists during the first pass' );

    ${$clock} = '2026-09-06T10:00:00Z';
    run_pass( $tira, $root, $store );

    my $late = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card created between the two passes' );
    ${$clock} = '2026-09-06T11:00:00Z';
    my $second = run_pass( $tira, $root, $store );

    my %seen = map { ( $_->{ref} // '' ) => 1 } @{ $second->{violations} || [] };
    ok( $seen{ $late->{ref} },
        'a card created between two passes is reported by the second one - the cache lives '
          . 'for a pass, not for the process' );

    my $found = eval { my @d = $tira->_record_data( project => $root, ref => $late->{ref} ); 1 };
    ok( $found, 'and the engine can still find it outside any pass' );
}

# --- a card created DURING a pass is not remembered as missing ---------------
#
# police_pass calls _raise_upgrade_gate, which creates a card while the pass is
# running. Caching a failed resolution would make that card unfindable for the
# rest of the pass, so a miss must not be cached.

{
    my ( $tira, $root, $store ) = board();

    $tira->_police_path_cache( sub {
        my $absent = 'WOT-404';
        my $before = eval { $tira->_record_data( project => $root, ref => $absent ); 1 } ? 1 : 0;
        is( $before, 0, 'a card that does not exist is not found, which is the state the '
              . 'upgrade gate starts from' );

        my $made = $tira->create_record( project => $root, type => 'ticket',
            title => 'a card raised while the pass was running' );

        my $after = eval {
            my @d = $tira->_record_data( project => $root, ref => $made->{ref} );
            1;
        } ? 1 : 0;
        is( $after, 1,
            'and a card created during the pass IS found afterwards - a resolution that '
              . 'failed must not be remembered, because the upgrade gate raises a card '
              . 'mid-pass and every later rule has to be able to see it' );
    } );
}

# --- the cache is scoped in the source, not left to a caller -----------------
#
# Read from the source because the behaviour above can be satisfied by a cache
# that a caller happens to clear. What this card claims is that the scope is
# the pass itself, so nothing can forget to.

{
    my $engine = Suite::engine_source();
    # non-empty is the whole claim: every check below would pass on an
    # unreadable file's emptiness alone.
    like( $engine, qr/\S/, 'the engine source is there to be read' );

    my ($pass) = $engine =~ /(sub \s+ police_pass \s* \{\n .*? \n\})/xs;
    like( $pass // '', qr/A violation store is required/,
        'police_pass was found, and is the one that refuses without a store - asserted by '
          . 'its content so a match on some other sub could not satisfy the check below' );
    like( $pass // '', qr/_police_path_cache/,
        'and it scopes the path cache to itself, so a pass cannot leak resolved paths into '
          . 'the next one and no caller has to remember to clear anything' );
}

done_testing();

__END__

=head1 NAME

582-a-board-walked-once-per-card.t - a police pass resolves each card's location once

=head1 DESCRIPTION

TKT-978. C<_record_data> locates a card by running C<File::Find> over all three
board trees every time it is called, and C<history_list> calls it before
reading each journal. On his zenandi copy that is 765 record lookups and 765
history reads against 349 cards - about 1,384 walks at 0.0095s each, some 10.6s
of a 14.11s pass, while reading the card a walk finds costs 0.0002s.

This holds the fix in place: within one pass each ref resolves to a path once,
between passes nothing is remembered, and a resolution that failed is not
remembered at all - because C<police_pass> raises the upgrade-gate card while
the pass is still running, and every rule after that point has to be able to
find it.

=cut
