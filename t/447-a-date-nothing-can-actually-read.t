#!/usr/bin/env perl
# TKT-633. _valid_datetime checks only the SHAPE of a date-time -
# /\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2}))\z/ -
# so month 13, day 45, hour 99 and an offset of +9999 all pass, because
# every field is only a digit count. The refusal it would print names ISO
# 8601, a standard the accepted values do not meet.
#
# _epoch_of_datetime is the OTHER validator in this file, the one police
# and dwell actually use to do arithmetic on these fields - and it refuses
# the same string outright, via Time::Local's own range check. So a card
# can be given a --due-date or --start-date that is stored happily by one
# validator and then kills whatever reads it back through the other.
#
# Reproduced against the pre-fix source: create_record accepts
# due_date => '2026-13-45T99:99:99Z' without complaint, and record_list's
# own since-filtering (which calls _epoch_of_datetime on stored stamps)
# would die reading that same record back.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-08-30T06:00:00Z'} );

$tira->project_new(
    name => 'Dates', dir => $root, members => ['claude'],
    columns    => [ 'backlog', 'done' ],
    sow_prefix => 'DTS', epic_prefix => 'DTE', ticket_prefix => 'DTT',
);

# --- the bug: an impossible date-time is accepted at write time -------------

my $bad = eval {
    $tira->create_record(
        project => $root, type => 'ticket', title => 'Nonsense due date',
        due_date => '2026-13-45T99:99:99Z',
    );
};
my $write_error = $@;

ok( !$bad, 'a due_date of month 13, day 45, hour 99 is refused at write time'
      . ' - if this is a real record, _valid_datetime accepted a value no'
      . ' calendar has' );
like( $write_error, qr/Due date/i, 'and the refusal names the field, the same shape every other field refusal takes' )
  if !$bad;
like( $write_error, qr/Month '13' out of range 1\.\.12/,
    "and names which part is wrong and the 1-indexed value actually typed, not Time::Local's own"
      . " 0-indexed internal one - a caller who typed 13 should never be told about 12" )
  if !$bad;

# --- control: a real, plausible-but-wrong date-time is still refused --------
# (Feb 30 does not exist in any year - a narrower case than the ticket's own
# reproduction, and worth pinning separately so a fix that only rejects
# triple-digit nonsense cannot pass this file.)

my $control = eval {
    $tira->create_record(
        project => $root, type => 'ticket', title => 'Feb 30th',
        due_date => '2026-02-30T00:00:00+0100',
    );
};
ok( !$control, 'February 30th is refused too - the fix checks the day against its actual month and year, not just digit ranges' );

# --- control: a genuinely valid date-time is still accepted ------------------

my $good = $tira->create_record(
    project => $root, type => 'ticket', title => 'Real due date',
    due_date => '2026-08-27T12:00:00+0100',
);
is( $good->{due_date}, '2026-08-27T12:00:00+0100', 'a genuinely valid ISO 8601 date-time is still accepted, unchanged' );

# --- the ticket's own fourth measured value: an impossible offset -----------
# _epoch_of_datetime does arithmetic with an offset's hours/minutes but never
# range-checks them, so delegating to it alone (the first pass of this fix)
# still let +9999 through - caught by Codex review before this card left
# document.

my $bad_offset = eval {
    $tira->create_record(
        project => $root, type => 'ticket', title => 'Impossible offset',
        due_date => '2026-08-27T12:00:00+9999',
    );
};
ok( !$bad_offset, 'an offset of +9999 is refused - the fourth value this ticket measured as accepted' );

done_testing();

__END__

=head1 NAME

t/447-a-date-nothing-can-actually-read.t - a due_date/start_date must be a
date-time something can actually read back, not just shaped like one

=head1 DESCRIPTION

C<_valid_datetime> validated only the shape of a date-time via regex, so
month 13, day 45, hour 99 and an offset of +9999 all passed - every field
was just a digit count. C<_epoch_of_datetime>, the other validator in this
file, does real range-checked arithmetic on the same fields (via
Time::Local) and refuses those same strings outright. A card could be
given a C<--due-date> or C<--start-date> that was stored happily and then
killed the next thing that tried to read it back. TKT-633.

=cut
