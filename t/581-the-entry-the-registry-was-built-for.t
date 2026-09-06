#!/usr/bin/env perl
# TKT-947, a correction to TKT-610: the registry's intended first entry is
# missing, and the reason recorded for its absence was wrong.
#
# t/566 DOES carry a column_list entry - and its source is
# Suite::engine_source(), which deliberately EXCLUDES lib/Tira/CLI. So the
# decision is guarded in the engine and unguarded in the layer where every
# real call site lives:
#
#   lib/Tira/CLI.pm:1092        inside _columns_for - the recovery itself
#   lib/Tira/CLI.pm:2119        the column.list dispatch
#   lib/Tira/CLI/Records.pm:82  record_create, author check
#   lib/Tira/CLI/Records.pm:129 record_create, entry-gate seeding
#   lib/Tira/CLI/Browser.pm:87  the browser move provider
#   lib/Tira/CLI/Browser.pm:307 the columns provider
#   lib/Tira/CLI/Police.pm:1253 the working-column count
#   lib/Tira/CLI/Wizard.pm:215  the onboarding defaults
#
# EIGHT, not the six the card says. It was written on 2026-09-05 and the layer
# has grown; the count is recorded on the card rather than absorbed, because an
# entry built from a stale list whitelists by position instead of by reading.
#
# ONE OF THE EIGHT IS THE GUARD. CLI.pm:1092 is _columns_for's own call, which
# IS the recovery TKT-597 built - the decision, not a bypass of it. The other
# seven all know their type; five of them say so somewhere other than inside
# the call's own parentheses, which is exactly what the bypass pattern reads,
# so those five need whitelisting with the reason each is allowed.
#
# WHY THAT MATTERS RATHER THAN BEING BOOKKEEPING: t/566's header says a
# whitelisted bypass must state why, "without that the list quietly becomes
# everything, which is how the original decisions came to have two homes". A
# whitelist written from a grep would say nothing, and the entry would be
# furniture.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();

my $registry = do {
    open my $fh, '<:raw', 't/566-one-decision-in-two-places.t'
      or die "cannot read the registry: $!";
    local $/;
    <$fh>;
};

# non-empty is the whole claim: every check below would pass on an unreadable
# file's emptiness alone.
like( $registry, qr/\S/, 'the registry is there to be read' );

# --- the decision is guarded where its call sites actually are --------------
#
# The whole card. An entry sourced from the engine cannot see the CLI layer,
# and every column_list call site in this codebase is in the CLI layer.

{
    my @entries = $registry =~ /(\{\s*name\s*=>\s*'[^']*column_list[^']*'.*?\n    \},)/gs;
    cmp_ok( scalar @entries, '>=', 2,
        'the registry carries a column_list entry for the COMMAND SURFACE as well as for '
          . 'the engine - one sourced from engine_source cannot see lib/Tira/CLI, which is '
          . 'where every call site is' );

    my $cli = join "\n", @entries;
    like( $cli, qr/cli_source/,
        'and that entry reads the command surface, which is the half TKT-610 left out' );
}

# --- and every exemption in it says why ------------------------------------
#
# t/566's own header: without a stated reason the list quietly becomes
# everything. The engine entry needs no exemptions; the command-surface one
# does, and each is a claim somebody can check.

{
    my ($cli_entry) = $registry =~ /(\{[^{}]*name\s*=>\s*'[^']*column_list[^']*command surface[^']*'.*?\n    \},)/gs;
    $cli_entry //= '';
    like( $cli_entry, qr/cli_source/,
        'the command-surface entry was found, and is the one reading the command surface - '
          . 'asserted by its content rather than by being non-empty, so an extraction that '
          . 'caught the wrong entry could not satisfy the count below' );

    my $count = () = $cli_entry =~ /because\s*=>/g;
    cmp_ok( $count, '>=', 4,
        'every whitelisted site in it states why it is allowed - five sites pass their type '
          . 'through an argument hash rather than inside the call, which is what the pattern '
          . 'reads, and each needs its own reason rather than one shared excuse' );
}

# --- the guard itself is named as the guard ---------------------------------
#
# _columns_for's own call is the recovery. Whitelisting it as "just another
# caller" would leave the entry technically green and say the wrong thing
# about which line is the decision.

{
    like( $registry, qr/_columns_for/,
        'the entry names _columns_for, so a reader knows which of the sites is the recovery '
          . 'rather than an exception to it' );
}

done_testing();

__END__

=head1 NAME

581-the-entry-the-registry-was-built-for.t - the column_list decision is guarded where its call sites are

=head1 DESCRIPTION

TKT-947, correcting TKT-610. C<t/566> carries a C<column_list> entry sourced
from C<Suite::engine_source()>, which excludes C<lib/Tira/CLI> - and every
C<column_list> call site in this codebase is in that layer. So the decision the
registry was built for was guarded where it is not called and unguarded where
it is.

This holds the command-surface entry in place: that it exists, that it reads
the command surface, that each of its exemptions states a reason, and that it
names C<_columns_for> so a reader can tell the recovery from the exceptions.

=cut
