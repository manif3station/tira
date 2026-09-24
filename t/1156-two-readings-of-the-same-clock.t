#!/usr/bin/env perl
# TKT-1156. lib/Tira.pm carries two independently-maintained readings of a
# card-duration policy's own verdict for one record: the inline
# elsif ( $rule eq 'card-duration' ) branch inside policy_evaluate (the
# real rule, ~line 8784), and _card_duration_inputs (~line 8073), extracted
# for police_explain (TKT-1106) to read "the same underlying facts" -
# but the inline branch's own body does not call the helper; it keeps its
# own separate computation of resting/watched/since/older-than. Nothing
# forces the two to agree if one changes and the other does not - the same
# drift class TKT-1147 closed for _item_is_exempt/_required_item_is_exempt.
#
# WRITTEN RED: the inline card-duration branch is still its own full
# implementation today, not a caller of _card_duration_inputs.

use strict;
use warnings;

use FindBin;
use Test::More;

use lib 'lib';
require Tira;

# --- THE BUG: two independently-maintained computations of the same facts -
# The inline branch should now call _card_duration_inputs rather than
# reimplementing _resting_columns/_policy_column_for/_dwell_start/
# _policy_older_than itself - so its own body should contain a call to the
# helper, and no longer call _policy_older_than directly (that call should
# live in exactly one place: _card_duration_inputs).

my $lib_path = "$FindBin::Bin/../lib/Tira.pm";
open my $fh, '<', $lib_path or die "cannot read $lib_path: $!";
my $source = do { local $/; <$fh> };
close $fh;

my ($branch_body) = $source =~ /elsif \( \$rule eq 'card-duration' \) \{(.*?)\n        \}\n        elsif/s;
isnt( $branch_body, undef, "the inline card-duration branch is still found in lib/Tira.pm" );

like( $branch_body, qr/_card_duration_inputs/,
    'the inline card-duration branch now calls _card_duration_inputs, sharing the one computation' )
  or diag('the inline branch still reimplements the facts itself instead of calling the shared helper');

unlike( $branch_body, qr/_policy_older_than/,
    'the inline branch no longer calls _policy_older_than directly - that reading now lives only in _card_duration_inputs' )
  or diag('the inline branch still has its own copy of the older-than-age comparison');

# --- Codex review: a resting/off-watched card must not gain TKT-972 stamp-
# unreadable tracking it never had ------------------------------------------
#
# The old inline branch called _policy_older_than (which records an
# unparseable stamp against _stamp_unreadable) only AFTER already skipping a
# resting card and a card off the watched column - so those cards were never
# measured at all. The first draft of this unification called
# _card_duration_inputs unconditionally for every record before checking
# would_fire, which would have called _policy_older_than (and so recorded
# stamp-unreadable) for a resting/off-watched card too - a real behavior
# change the ticket's own "no behavior change" claim did not intend. Confirm
# the helper's own body only passes $record->{ref} through when the card is
# both resting-clear and on the watched column, the same gate the old inline
# short-circuit applied.

my ($helper_body) = $source =~ /sub _card_duration_inputs \{(.*?)\n\}/s;
isnt( $helper_body, undef, '_card_duration_inputs is still defined in lib/Tira.pm' );

like( $helper_body,
    qr/_policy_older_than\(\s*\n?\s*\$since,\s*\$policy->\{age\},\s*\n?\s*\(\s*!\$resting_here\s*&&\s*\$on_watched\s*\?\s*\$record->\{ref\}\s*:\s*undef\s*\)/s,
    'the ref argument to _policy_older_than is scoped to resting-clear, on-watched cards only - not passed unconditionally' )
  or diag('the helper now records stamp-unreadable for cards the old inline rule never measured at all');

done_testing;

__END__

=head1 NAME

1156-two-readings-of-the-same-clock.t - policy_evaluate's inline
card-duration branch and _card_duration_inputs are unified into one
code path

=head1 DESCRIPTION

TKT-1156. Confirms the inline C<elsif ( $rule eq 'card-duration' )> branch
inside C<policy_evaluate> now calls C<_card_duration_inputs> rather than
independently reimplementing the same resting/watched/since/older-than
computation that helper already extracted for C<police_explain>
(TKT-1106) - so the rule's own verdict and its own explanation can no
longer silently disagree, the same drift class TKT-1147 closed for
C<_item_is_exempt>/C<_required_item_is_exempt>.

=cut
