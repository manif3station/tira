#!/usr/bin/env perl
# The bridge has to carry the owner's own words.
#
# He works this board in English and Cantonese, and on 2026-08-12 his terminal
# filled with "Wide character in print at lib/Tira.pm" while police was running
# - eight of them, from one pass. bridge_write opened the log raw and printed
# text straight into it, so a card titled in anything but ASCII warned on his
# screen and wrote bytes that could not be read back.
#
# Everything else in this codebase had already learned to speak bytes on
# purpose: the YAML shim encodes before writing, the journal writes through
# ->utf8->encode. The bridge is the one channel that was missed - and it is the
# only channel police has.
#
# Warnings are fatal here. A warning printed and ignored is exactly how this
# survived to reach him.

use strict;
use warnings;
use utf8;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-12T19:00:00Z'} );
my $store = File::Spec->catdir( $tmp, 'police-state' );

# 這張卡 - "this card", the sort of title he actually writes - plus an accent
# and a curly quote, because ASCII-adjacent characters break in quieter ways.
my $chinese = "\x{9019}\x{5F35}\x{5361}";
my $accented = "caf\x{e9} \x{2014} the owner\x{2019}s words";

my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };

my $written = $tira->bridge_write(
    store => $store,
    violations => [
        { id => 'VIO-0001', ref => 'TKT-001', rule => 'card-full-details',
            detail => $chinese, action => 'bridge-reminder', tone => 'note' },
        { id => 'VIO-0002', ref => 'TKT-002', rule => 'card-stalled',
            detail => $accented, action => 'bridge-reminder', tone => 'note' },
    ],
);

is( $written, 2, 'both violations are written to the bridge' );
is_deeply( \@warnings, [],
    'and nothing warns - a wide character is an ordinary card title, not an error' )
  or diag( 'warned: ' . join ' ', @warnings );

# --- and it reads back as what was written --------------------------------
#
# Writing without warning is only half of it. A line that goes in as Chinese
# and comes out as mojibake is a bridge that has lost the message while
# reporting success.

my $backlog = $tira->bridge_backlog( store => $store, lines => 10 );
is( scalar @{$backlog}, 2, 'both lines are read back' );

ok( ( grep { index( $_, $chinese ) >= 0 } @{$backlog} ),
    'the Chinese title survives the round trip' );
ok( ( grep { index( $_, $accented ) >= 0 } @{$backlog} ),
    'and so do the accent and the curly quote' );

# --- the bytes on disk are the encoding we claim --------------------------
#
# Proved at the file rather than through the reader, because a writer and a
# reader that are wrong in the same direction agree with each other perfectly.

my $path = $tira->bridge_log_path( store => $store );
open my $raw, '<:raw', $path or die "cannot read the bridge log: $!";
my $bytes = do { local $/; <$raw> };
close $raw;

like( $bytes, qr/\xE9\x80\x99\xE5\xBC\xB5\xE5\x8D\xA1/,
    'the log holds UTF-8 bytes on disk, which is what every other file here holds' );
ok( !utf8::is_utf8($bytes) || $bytes !~ /[^\x00-\xFF]/,
    'and nothing was written as a raw wide character, which no reader could interpret' );

# --- an agent filtering the bridge still finds its own lines --------------
#
# The filter matches on text. Encoding the line without teaching the filter
# would make an agent with a non-ASCII card silently hear nothing, which is the
# failure this whole channel exists to prevent.

my $named = $tira->bridge_write(
    store => $store,
    violations => [ { id => 'VIO-0003', ref => 'TKT-003', rule => 'card-stalled',
            detail => $chinese, assignee => 'ada', action => 'bridge-reminder', tone => 'note' } ],
);
is( $named, 1, 'a violation addressed to an agent is written' );

my $hers = $tira->bridge_backlog( store => $store, agent => 'ada', lines => 10 );
ok( ( grep { index( $_, $chinese ) >= 0 } @{$hers} ),
    'and the agent it belongs to still finds it, wide characters and all' );

is_deeply( \@warnings, [], 'still nothing has warned, on any path' )
  or diag( 'warned: ' . join ' ', @warnings );

done_testing();

__END__

=head1 NAME

108-bridge-speaks-utf8.t - the bridge has to carry the owner's own words

=head1 DESCRIPTION

This board is worked in English and in Cantonese. On 2026-08-12 the owner's
terminal filled with wide-character warnings while police was running, because
the bridge log was opened raw and text was printed straight into it. A card
titled in anything but ASCII warned on his screen and wrote bytes that could
not be read back.

Everything else here had already learned to speak bytes deliberately: the YAML
shim encodes before writing, and the journal encodes before writing. The bridge
was the one channel that was missed, and it is the only channel police has.

Warnings are failures in this file. A warning printed and ignored is exactly
how this survived long enough to reach him.

=cut
