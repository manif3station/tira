#!/usr/bin/env perl
# TKT-828. outstanding_summary's own comment (lib/Tira.pm, directly above the
# sub) claims: "questions reuses the identical _policy_questions/_card_blocked
# logic the dashboard and work_order already use, so the two cannot
# disagree." The code did not call _card_blocked at all - it reimplemented
# the same check inline. Currently harmless (the inline copy happens to
# match), but two implementations of one boolean is exactly the drift this
# project has been bitten by before (TKT-713, two validators for one
# format) - a future edit to _card_blocked's own discard-handling would
# silently stop being reflected here.
#
# THIS TEST DOES NOT PROVE A BEHAVIOR CHANGE - the fix is a pure refactor,
# and t/475 (TKT-808's own file) is run unchanged to confirm that. This file
# instead pins outstanding_summary to actually CALLING _card_blocked, so a
# future re-divergence is caught structurally rather than only by luck
# matching in a behavioral test.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;

# --- the source itself calls _card_blocked, not a reimplementation ---------

my $source = Suite::engine_source();
my ($sub_body) = $source =~ /sub outstanding_summary \{(.*?)\n\}\n/s;
ok( $sub_body, 'outstanding_summary\'s own body was found in the engine source' );
like( $sub_body, qr/&&\s*_card_blocked\(\s*\$_\s*\)/,
    'and it, specifically, calls _card_blocked($_) directly - matching its own comment\'s claim, '
      . 'not just some unrelated call elsewhere in the file' );

# --- and a discarded, unanswered question is not blocking - the exact case
# --- an inline reimplementation missing _policy_questions' own
# --- discarded_at skip would get wrong ---------------------------------

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-09T12:00:00+0100' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Discarded', dir => $root, members => ['ada'],
    columns => ['backlog, doing, done'],
    sow_prefix => 'DSS', epic_prefix => 'DSE', ticket_prefix => 'DST',
);

my $card = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'a card' );
my $q = $tira->question_add( project => $root, ref => $card->{ref}, author => 'ada', text => 'Which way?', reason => 'unsure' );
$tira->question_discard( project => $root, ref => $card->{ref}, id => $q->{id}, author => 'ada' );

my $summary = $tira->outstanding_summary( project => $root );
is( $summary->{questions}, 0,
    'a discarded, never-answered question does not count as blocking - matches _card_blocked\'s own discarded_at skip' );

done_testing();

__END__

=head1 NAME

t/828-a-count-that-forgot-a-name.t - outstanding_summary calls _card_blocked
directly instead of reimplementing its check

=head1 DESCRIPTION

TKT-828. C<outstanding_summary>'s own comment claimed it reused
C<_card_blocked>'s logic; the code instead reimplemented the same
unanswered-question check inline, currently matching by coincidence rather
than by construction. Fixed by replacing the inline
C<grep { grep { !$_->{answer} } _policy_questions($_) }> with
C<grep { _card_blocked($_) }>, the same alias-not-reimplementation pattern
C<_card_waiting> already follows for the identical check.

=cut
