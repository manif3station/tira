#!/usr/bin/env perl
# TKT-980. His own question: "unpushed-work --pattern: what does it match
# against, and would it catch a sandbox clone?" - raised because guessing the
# semantics and writing a proof on the guess is the failure mode this project
# keeps recording (Q-120/Q-122, TKT-933).
#
# THE ANSWER, found by reading rather than guessing: unpushed-work's own rule
# body (lib/Tira.pm) never reads $policy->{pattern} at all - only two rules
# do, leftover-process and leftover-container, and %POLICY_RULES declares
# pattern in `needs` for both of them. unpushed-work's own spec neither needs
# nor forbids it, so POL-130 (rule unpushed-work, pattern CODE, age 4h) was
# accepted, stored, and read back correctly - which is exactly what made it
# credible. The same shape TKT-933 already fixed for card-stalled's ignored
# --age, applied here to a different option on a different rule.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Pattern Nothing Reads', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'PNS', epic_prefix => 'PNE', ticket_prefix => 'PNT',
);

# --- a pattern on unpushed-work is refused, not silently stored -------------

my $refused = !eval {
    $tira->policy_add( project => $root, rule => 'unpushed-work',
        pattern => 'CODE', age => '4h', action => 'bridge-reminder' );
    1;
};
ok( $refused, 'unpushed-work refuses a pattern rather than quietly storing one nothing reads' )
  or diag('policy_add accepted --pattern on unpushed-work');
like( $@, qr/takes no --pattern/, 'and says so in the words somebody typing it would read' );

# --- and the rule still works exactly as before without one -----------------

my $ok = eval {
    $tira->policy_add( project => $root, rule => 'unpushed-work',
        age => '4h', action => 'bridge-reminder' );
    1;
};
ok( $ok, 'declaring unpushed-work with no pattern is unchanged' ) or diag($@);

done_testing();

__END__

=head1 NAME

596-a-pattern-nothing-reads.t - unpushed-work refuses a --pattern it never read

=head1 DESCRIPTION

TKT-980. C<unpushed-work> accepted C<--pattern>, stored it, and showed it
back - and the rule's own body never once reads it; only C<leftover-process>
and C<leftover-container> do, and both declare it in C<needs>.
C<unpushed-work>'s spec neither needed nor forbade it, so a declared pattern
did exactly nothing, silently - the same shape C<card-stalled>'s ignored
C<--age> had (TKT-933). Fixed by adding C<pattern> to C<unpushed-work>'s own
C<forbids> list, refusing it at declare time through the same generic check
every other forbidden option already uses.

=cut
