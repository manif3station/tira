#!/usr/bin/env perl
# _iso_from_epoch, the only formatter behind rule.suspend's and rule.decline's
# 'until' field, hardcodes UTC - a second timestamp convention nobody chose on
# purpose, for exactly these two fields, while every other timestamp this
# project writes (created_at, last_updated, comment and gate timestamps) comes
# from the default clock, which deliberately computes and writes the real
# local offset - t/96 already proves that clock right, zone by zone.
#
# Measured this session: roughly ten tira.rule.suspend calls each returned an
# until field like '2026-08-19T08:47:30Z' sitting on the same card as
# created_at/last_updated timestamps in +0100 - two conventions on one card,
# every time, and a reader has to convert by hand to compare them. TKT-419.

use strict;
use warnings;

use POSIX ();
use Test::More;

use lib 'lib';
use Tira;

# The clock's own promise, from t/96: a numeric offset, correct for the zone.
# _iso_from_epoch answers the same question - "when, in this project's own
# timestamp convention" - and should keep the same promise.
SKIP: {
    skip 'this system does not take a named time zone from the environment', 4
      if !eval { POSIX::tzset(); 1 };

    my $epoch = 1_755_000_000;    # an arbitrary, fixed moment

    local $ENV{TZ} = 'Asia/Hong_Kong';
    POSIX::tzset();
    unlike( Tira::_iso_from_epoch($epoch), qr/Z\z/,
        'the until field is not a bare Z where the board has a real offset' );
    like( Tira::_iso_from_epoch($epoch), qr/\+0800\z/,
        'and it carries the offset the zone actually has' );

    local $ENV{TZ} = 'America/New_York';
    POSIX::tzset();
    like( Tira::_iso_from_epoch($epoch), qr/-0[45]00\z/,
        'west of UTC the sign is negative, not silently right by using Z instead' );

    # Even where the offset happens to be zero, the convention should still be
    # the clock's own +0000, not a differently-spelled UTC that reads as a
    # second format the moment the board is anywhere else.
    local $ENV{TZ} = 'UTC';
    POSIX::tzset();
    like( Tira::_iso_from_epoch($epoch), qr/\+0000\z/,
        'and at the zone with no offset it still spells it the clock\'s way' );
}

# The board's own default clock and _iso_from_epoch answering the same
# instant should read alike - proved directly, not just by shape.
{
    my $epoch = 1_755_000_000;
    my @local = localtime $epoch;
    my $expected_day = POSIX::strftime( '%Y-%m-%d', @local );
    like( Tira::_iso_from_epoch($epoch), qr/\A\Q$expected_day\E/,
        'the date printed is the local date for the moment, not the UTC one' );
}

done_testing;

__END__

=head1 NAME

292-a-second-clock-nobody-chose.t - until reads like every other timestamp

=head1 DESCRIPTION

_iso_from_epoch, the only formatter behind rule.suspend's and rule.decline's
until field, hardcoded UTC via gmtime while every other timestamp this
project writes comes from a clock that deliberately computes the real local
offset. This holds _iso_from_epoch to the same promise t/96 already proves
for the default clock: a numeric offset correct for the zone, in the same
format, not a second convention.

=cut
