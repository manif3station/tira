#!/usr/bin/env perl
# TKT-727. SETTLED means only "absent from this pass's findings" - never that
# the underlying condition was checked and found fixed. A rule settling
# because it was put down (rule_suspend) and a rule settling because the
# condition genuinely cleared produce the identical settled=>1 with nothing
# to tell them apart, which is exactly the report: card-sandbox-missing
# SETTLED on DD-652 with every underlying fact unchanged.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-09-27T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
sub at { $now = $_[0]; return $now }

sub condition {
    my (%args) = @_;
    return {
        rule => 'card-stalled', policy => 'POL-001', ref => 'TKT-001',
        detail => 'every checklist item is done but the card is still in implement',
        action => 'bridge-reminder', %args,
    };
}

# --- a settlement with nothing between passes says it was never re-checked -

my $store = File::Spec->catdir( $tmp, 'police-state' );
$tira->violation_record( store => $store, violations => [ condition() ] );

at('2026-09-27T09:10:00Z');
my ( undef, $settled ) = $tira->violation_record( store => $store, violations => [] );
is( scalar @{$settled}, 1, 'the condition settles' );
is( $settled->[0]{reason}, 'no-longer-detected',
    'and the settlement says only that this pass did not find it again - not that it was fixed' );

# --- a rule put down settles for a different, distinguishable reason ------

my $store2 = File::Spec->catdir( $tmp, 'suspended' );
$tira->violation_record( store => $store2, violations => [ condition( ref => 'TKT-002' ) ] );

at('2026-09-27T09:20:00Z');
$tira->rule_suspend( store => $store2, rule => 'card-stalled', ref => 'TKT-002',
    seconds => 60, reason => 'TKT-727 test' );

my ( undef, $settled2 ) = $tira->violation_record( store => $store2, violations => [] );
is( scalar @{$settled2}, 1, 'the suspended rule also settles' );
is( $settled2->[0]{reason}, 'policy-suspended',
    'but says the rule was put down, rather than reading identically to a real fix' );

# --- the bridge line stops asserting a fact nobody checked ----------------

my $line = $tira->_bridge_settled_line( $settled->[0] );
unlike( $line, qr/no longer applies here/,
    'the settlement line no longer states as fact that the rule stopped applying' );

my $line2 = $tira->_bridge_settled_line( $settled2->[0] );
like( $line2, qr/suspended/i,
    'and a settlement caused by suspension says so in the bridge line itself' );

done_testing;

__END__

=head1 NAME

727-a-settlement-that-does-not-say-why.t - a settled violation now says why

=head1 DESCRIPTION

Follow-up to TKT-726: card-sandbox-missing SETTLED on DD-652 with every
underlying fact unchanged. Read from the code (CMT-001 on TKT-727), settled
means only "the key was open and is absent from this pass's findings" - a
real fix and a rule being put down produce the byte-identical signal.

Michael's answer to Q-190: record a reason when anything settles, as a
general ledger fix. This test proves two distinguishable reasons come out of
C<violation_record>: C<policy-suspended> when the rule was put down via
C<rule_suspend> before the settling pass, and C<no-longer-detected> as the
honest default otherwise - and that the bridge SETTLED line reflects the
difference instead of unconditionally asserting the rule "no longer applies
here".

=cut
