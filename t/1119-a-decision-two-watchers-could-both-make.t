#!/usr/bin/env perl
# TKT-1114. Reproduced live: 5+ concurrent 'd2 tira.dashboard' monitor
# processes against the same board all detected the same 5.131->5.137
# version jump and each self-filed its own upgrade-review card
# (TKT-1110/1111/1112 - identical title, identical range, filed within
# minutes of each other).
#
# THE RACE, read in the source before this ticket. The announced-version
# check inside _police_pass_body read the enforcement store ONCE (shared
# with the card-damaged/card-unreadable tracking above it), decided whether
# the version had genuinely changed, and only then wrote the updated store
# and raised a gate card - with nothing holding a lock across that
# read-decide-write span. Two watchers that both read the store before
# either had written it back both saw the same "not yet announced" state
# and both raised their own card.
#
# THE FIX moves that decision into its own method, _announce_upgrade,
# which re-reads the store FRESH inside the project lock rather than
# trusting a read taken before the lock. A second watcher racing in only
# gets the lock after the first has already written, and its own fresh
# read then shows the change already recorded.
#
# A genuine two-process race is exactly what this bug needed to reproduce
# live, and is exactly what a deterministic test suite should not try to
# force - a monkeypatched "concurrent" call landing at the wrong one of
# several _enforcement_read call sites in one pass proved fragile to write
# and no more convincing than reading the fix straight from its own
# source, the way t/575 and t/582 already do for this same class of claim.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;
use lib 't/lib';
use Suite ();

my $engine = Suite::engine_source();
# non-empty is the whole claim: every check below would pass on an
# unreadable file's emptiness alone otherwise.
like( $engine, qr/\S/, 'the engine source is there to be read' );

my ($body) = $engine =~ /(sub \s+ _police_pass_body \s* \{ .*? \n \})/xs;
ok( $body, 'the pass body was found' );
unlike( $body // '', qr/_raise_upgrade_gate/,
    "and it no longer raises the gate card directly - that decision moved into "
      . 'a method with its own lock, so the pass body cannot reach it unlocked '
      . 'even by a future edit that forgets why' );

my ($announce) = $engine =~ /(sub \s+ _announce_upgrade \s* \{ .*? \n \})/xs;
ok( defined $announce, 'the extracted announce-upgrade method was found' );

like( $announce // '', qr/_with_project_lock/,
    'and it is wrapped in the project lock, so two watchers racing the same '
      . 'enforcement store cannot both decide before either writes' );

# THE ORDER MATTERS, so this does not just grep the whole method for both
# strings - a locked callback that reads nothing, followed by a read once
# the lock has already been released, would satisfy that and change
# nothing about the race. Captured by its own closing line (a lone
# 4-space-indented "} );", the shape this file's own callback closes
# with - not `.*?\n\}` alone, which nested if/elsif blocks inside the
# callback would satisfy first at their own 8-space-indented "}").
my ($callback) = $announce =~
  /_with_project_lock\s*\(\s*\$root\s*,\s*sub\s*\{(.*?)\n {4}\}\s*\);/s;
ok( defined $callback,
    "found the callback _with_project_lock actually runs, bounded by its own closing "
      . 'line rather than the first brace anywhere in the method' );

like( $callback // '', qr/\A\s*my \$quieted = \$self->_enforcement_read/,
    'and the very first thing that callback does, once it holds the lock, is its own '
      . 'fresh read of the enforcement store - not a value the caller read before '
      . 'taking the lock, which a locked block merely guarding a stale read would still '
      . 'leave racing' );

done_testing();

__END__

=head1 NAME

1119-a-decision-two-watchers-could-both-make.t - the upgrade-announce decision is locked and re-reads fresh

=head1 DESCRIPTION

TKT-1114. Two watchers running a pass at nearly the same moment could both
read the enforcement store's "not yet announced" state before either wrote
it back, so both decided a version change was news and both raised their
own upgrade-gate card - reproduced live as three identical duplicate
cards, TKT-1110/1111/1112. The decision is now in its own method,
C<_announce_upgrade>, which re-reads the store inside C<_with_project_lock>
rather than trusting a pre-lock read, so a second watcher only gets the
lock after the first has already written and sees its own change already
recorded.

=cut
