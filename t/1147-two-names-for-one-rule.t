#!/usr/bin/env perl
# TKT-1147. lib/Tira.pm carries two independently-maintained,
# byte-identical implementations of the same exempt-matching predicate:
# _item_is_exempt (record_move's departure gate) and
# _required_item_is_exempt (the required-action-stranded police rule).
# Both check id first, refuse text-matching for REQ-shaped text, then
# match by exact text - identical logic under two names, nothing forcing
# them to stay in sync (the same drift class TKT-1084 itself closed for
# a different pair).
#
# WRITTEN RED: _required_item_is_exempt is still its own full
# implementation today, not a forward to _item_is_exempt.

use strict;
use warnings;

use Test::More;
use FindBin;

use lib 'lib';
require Tira;

# --- behavioural parity: both must agree on every case, before and after
# --- the unification ------------------------------------------------------

my %exempt_by_id   = ( 'REQ-001' => 1 );
my %exempt_by_text = ( 'Some free-text item' => 1 );

for my $case (
    [ 'id match',                  \%exempt_by_id,   { id => 'REQ-001', item => 'anything' }, 1 ],
    [ 'no id match, no text',      \%exempt_by_id,   { id => 'REQ-002', item => undef },       0 ],
    [ 'REQ-shaped text refused',   \%exempt_by_text, { id => undef, item => 'REQ-001' },       0 ],
    [ 'exact text match',          \%exempt_by_text, { id => undef, item => 'Some free-text item' }, 1 ],
    [ 'text does not match',       \%exempt_by_text, { id => undef, item => 'Different text' },      0 ],
  )
{
    my ( $label, $exempt, $item, $expect ) = @$case;
    is( Tira::_item_is_exempt( $exempt, $item ),          $expect, "_item_is_exempt: $label" );
    is( Tira::_required_item_is_exempt( $exempt, $item ), $expect, "_required_item_is_exempt: $label" );
}

# --- THE BUG: two independently-maintained copies of the same logic ------
# _required_item_is_exempt should now be a thin forward to _item_is_exempt,
# not its own full reimplementation - so its own body should no longer
# contain the REQ-shape refusal regex literal; that logic should live in
# exactly one place (_item_is_exempt).

my $lib_path = "$FindBin::Bin/../lib/Tira.pm";
open my $fh, '<', $lib_path or die "cannot read $lib_path: $!";
my $source = do { local $/; <$fh> };
close $fh;

my ($required_body) = $source =~ /sub _required_item_is_exempt \{(.*?)\n\}/s;
isnt( $required_body, undef, '_required_item_is_exempt is still defined in lib/Tira.pm' );

unlike( $required_body, qr/\\AREQ-\\d\+\\z/,
    '_required_item_is_exempt no longer duplicates the REQ-shape refusal regex - it forwards to _item_is_exempt instead' )
  or diag('the exempt-matching logic is still independently reimplemented in two places');

done_testing;

__END__

=head1 NAME

1147-two-names-for-one-rule.t - _item_is_exempt and _required_item_is_exempt
are unified into one function

=head1 DESCRIPTION

TKT-1147. Confirms both call sites still agree on every exemption case
(id match, REQ-shaped text refusal, exact text match, no match), and that
_required_item_is_exempt's own body no longer independently reimplements
the REQ-shape refusal regex - it must forward to _item_is_exempt so the
two names cannot drift out of sync again.

=cut
