#!/usr/bin/env perl
# TKT-582. The ISO 8601 grammar Tira accepts is written out twice:
# _epoch_of_datetime (the instant-based comparison CA04 uses, offset
# optional - a missing one reads as UTC) and _valid_datetime (the stored
# due/start date validator, offset required since TKT-572). The two copies
# already drifted once - TKT-572 fixed _valid_datetime's rejection of a
# form _epoch_of_datetime already accepted, and nothing stopped it
# happening again for the next form either copy might need to change.
#
# This asserts the two entry points agree on every value they both accept,
# so a future change to the shared grammar's core (not the one documented
# difference, offset-required) cannot silently reach only one of them.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;
use Suite ();

my $tira = Tira->new;

# --- the grammar itself lives in exactly one place --------------------------
#
# The behavioural agreement below would pass even with two copies that
# happen to still agree today - which is exactly the state TKT-572 found
# and fixed once already, silently. What proves the two copies are now
# actually ONE is structural: both subs call the same shared pattern
# builder, rather than each carrying its own regex literal.

my $engine_source = Suite::engine_source();
my ($epoch_body) = $engine_source =~ /\Qsub _epoch_of_datetime\E\s*\{(.*?)\n\}/s;
my ($valid_body)  = $engine_source =~ /\Qsub _valid_datetime\E\s*\{(.*?)\n\}/s;
ok( defined $epoch_body, '_epoch_of_datetime was found to inspect' );
ok( defined $valid_body,  '_valid_datetime was found to inspect' );
like( $epoch_body, qr/_iso8601_pattern/,
    '_epoch_of_datetime calls the shared pattern builder rather than carrying its own regex' );
like( $valid_body, qr/_iso8601_pattern/,
    '_valid_datetime calls the shared pattern builder rather than carrying its own regex' );

# --- values both entry points accept, with and without an offset ----------

my @with_offset = (
    '2026-08-19T09:00:00Z',
    '2026-08-19T09:00:00+0100',
    '2026-08-19T09:00:00+01:00',
    '2026-08-19T09:00:00-05:30',
    '2026-08-19T09:00:00.123Z',
);

for my $value (@with_offset) {
    my $epoch = eval { Tira::_epoch_of_datetime( $value, 'Threshold' ) };
    ok( defined $epoch, "_epoch_of_datetime accepts $value" );
    my $valid = eval { $tira->_valid_datetime( $value, 'Field' ) };
    is( $valid, $value, "_valid_datetime agrees and accepts $value" );
}

# --- the one documented difference: a missing offset -----------------------

my $bare = '2026-08-19T09:00:00';
my $epoch_bare = eval { Tira::_epoch_of_datetime( $bare, 'Threshold' ) };
ok( defined $epoch_bare, '_epoch_of_datetime accepts a bare value, reading it as UTC' );
eval { $tira->_valid_datetime( $bare, 'Field' ) };
like( $@, qr/must be an ISO 8601 date-time with a timezone/,
    '_valid_datetime still refuses the same bare value - a timezone is mandatory here' );

# --- a malformed value is refused by both -----------------------------------

for my $bad ( 'not-a-date', '2026-13-40T99:99:99Z', '2026-08-19 09:00:00Z' ) {
    # Codex review: asserting only `undef` back would still pass a future
    # change from die() to a silent `return undef` - not the "refuses"
    # contract this ticket's own acceptance criteria describe. $@ is
    # checked non-empty too, so a swallowed failure cannot look identical
    # to a refusal.
    my $epoch = eval { Tira::_epoch_of_datetime( $bad, 'Threshold' ) };
    ok( !defined $epoch, "_epoch_of_datetime refuses $bad" );
    ok( length $@, "...by dying, not by silently returning undef" );
    my $valid = eval { $tira->_valid_datetime( $bad, 'Field' ) };
    ok( !defined $valid, "_valid_datetime also refuses $bad" )
      or diag("accepted: " . ( $valid // 'undef' ));
    ok( length $@, "...by dying too, not by silently returning undef" );
}

done_testing;

__END__

=head1 NAME

t/1076-a-grammar-with-two-copies.t - _epoch_of_datetime and _valid_datetime
agree on every ISO 8601 form they both accept

=head1 DESCRIPTION

TKT-582. The ISO 8601 grammar was written twice, and the two copies had
already drifted once (TKT-572). This drives the same value set through
both entry points and asserts they agree on everything except the one
documented difference - C<_valid_datetime> requires a timezone offset,
C<_epoch_of_datetime> reads a missing one as UTC - so a future change to
the shared grammar's core cannot silently reach only one of them.

=cut
