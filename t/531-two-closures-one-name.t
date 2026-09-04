#!/usr/bin/env perl
# A monitor's words, passed to a function that could not receive them.
#
# TKT-925, EPC-014. His question, 2026-09-04: "i am worry that why the tg message
# didn't pick up even the police announce there are new message on the tira
# policy bridge".
#
# THERE ARE TWO CLOSURES CALLED $report IN lib/Tira.pm AND THEY DO NOT AGREE:
#
#   7022  in policy_evaluate:                 ( $policy, $record, $detail, $for, $sub_key )
#   9422  in _police_environment_violations:  ( $policy, $ref,    $detail )
#
# monitor-output lives at 9654, inside the second, and calls it with five:
#
#   $report->( $policy, undef, "$job->{id} said: $said", undef, "$job->{id}:$said" );
#
# The fourth and fifth are discarded, and the violation that closure builds has
# no sub_key at all. The ledger fingerprint is rule|policy|ref|sub_key, so with
# neither a ref nor a sub_key EVERY monitor-output finding this board has ever
# made - every monitor, every pass, every different set of words - is ONE ledger
# entry. The quiet ladder marks each telling after the first as quiet, and
# bridge_write skips quiet violations.
#
# So the first monitor-output finding a board ever makes reaches the bridge and
# nothing does afterwards. Measured here: one entry in three weeks and 49,156
# lines, and it is JOB-005's Perl warning from the day the feature landed.
#
# AND THE WORDS ARE DESTROYED AFTER BEING SILENCED, which is the half that makes
# this worse than a missing line. advance_monitor_output drains on spoke, and
# spoke is set from the same condition that CALLS $report - so it is true when
# $report returned early, and true when bridge_write skipped the violation. The
# monitor's output is taken off the record either way.
#
# THE AUTHOR KNEW. The comment above the call still reads: "the quiet ladder keys
# on it, so two passes carrying different words must not look like one rule
# repeating itself." Correct in every word, and handed to a function with three
# parameters.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite qw(engine_source);
use Tira;

# --- the two closures agree ---------------------------------------------------
#
# THE META-GUARD, and it is the point of the file. Fixing monitor-output alone
# leaves two same-named closures with different shapes in one module, which is
# the trap the next rule written by copying a neighbour falls into. This is the
# assertion that stops it happening again rather than the one that fixes today.
#
# Read through Suite's walker rather than by opening lib/Tira.pm by name: this
# board has had three lifts reported as regressions by tests that named a file,
# and TKT-921 is open for the thirty-one that still do.

my $engine = engine_source();

my @signatures = $engine =~ /my \s \$report \s* = \s* sub \s* \{ \s* my \s* \( ([^)]*) \)/xgs;

cmp_ok( scalar @signatures, '>=', 2,
    'the engine declares more than one $report closure - which is the '
      . 'circumstance this file exists for' );

{
    my %arity = map { ( scalar( split /\s*,\s*/, $_ ) => 1 ) } @signatures;

    is( scalar keys %arity, 1,
        'AND EVERY $report CLOSURE TAKES THE SAME NUMBER OF THEM. Today one '
          . 'takes five and the other three, both called $report in one file, '
          . 'so a rule written by copying a neighbour from the other sub loses '
          . 'its last two arguments in silence - which is exactly what '
          . 'monitor-output does with its sub_key' )
      or diag( "signatures seen:\n" . join "\n", map {"  ($_)"} @signatures );

    # THE NAMES ARE NOT ASSERTED EQUAL, and that is deliberate rather than a
    # weakening. One closure takes a record and the other a bare ref, so the
    # second parameter is legitimately named differently; demanding identical
    # text would force a rename that makes one of them lie. What has to match is
    # the arity and the last two positions, because those are what a call
    # written against the wrong one gets wrong.
    my @tails = map { [ ( split /\s*,\s*/, $_ )[ -2, -1 ] ] } @signatures;
    my %tail = map { ( join( ',', @{$_} ) => 1 ) } @tails;

    is( scalar keys %tail, 1,
        'and the last two mean the same thing in both - $for and $sub_key, '
          . 'the two a caller is most likely to get from the wrong closure' )
      or diag( "tails seen: " . join '; ', sort keys %tail );
}

# --- and a monitor's words reach the ledger as their own entry -----------------
#
# The behaviour, so the file does not rest on a source assertion alone. Two
# passes carrying DIFFERENT words must not collapse into one entry, because that
# is what the quiet ladder reads as a rule repeating itself.

my ( $tira, $root );
{
    my $tmp = tempdir( CLEANUP => 1 );
    $root = File::Spec->catdir( $tmp, 'board' );
    $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Bridge', dir => $root,
        members => ['claude'], columns => ['backlog, done'],
        sow_prefix => 'BRS', epic_prefix => 'BRE', ticket_prefix => 'BRT',
    );
}

# The fingerprint is what the ledger keys on, and it is what decides whether two
# findings are the same problem. Asking it directly is narrower and clearer than
# running two passes and inspecting what survived the ladder.
my $fingerprint = Tira->can('_violation_key');

ok( $fingerprint, 'the ledger key is there to ask - _violation_key, which is what 
    the ledger fingerprints an entry by' );

SKIP: {
    skip 'no fingerprint to ask', 2 if !$fingerprint;

    my $first = $fingerprint->(
        { rule => 'monitor-output', policy => 'POL-001', ref => '',
          sub_key => 'JOB-001:one thing' } );
    my $second = $fingerprint->(
        { rule => 'monitor-output', policy => 'POL-001', ref => '',
          sub_key => 'JOB-001:something else entirely' } );

    isnt( $first, $second,
        'two findings carrying different words are different ledger entries - '
          . 'the property monitor-output needs and the reason it passes a '
          . 'sub_key at all' );

    my $without = $fingerprint->(
        { rule => 'monitor-output', policy => 'POL-001', ref => '' } );

    isnt( $first, $without,
        'and a finding WITH a sub_key is not the same entry as one without, '
          . 'which is what makes the dropped argument observable rather than '
          . 'merely untidy' );
}

# --- and a real pass produces one entry per set of words ----------------------
#
# THE ASSERTION THAT ACTUALLY BITES. The two above pass against unfixed code,
# because _violation_key already keys on a sub_key - the ledger was never the
# problem. The problem is that monitor-output's violations never CARRY one, so
# this runs the rule and looks at what it built.
#
# No processes are spawned: job_started records a pid the way the CLI does, and
# job_feed puts words on the record the way the feeder does. What is being
# tested is the rule, not the monitor.

{
    my $policy = $tira->policy_add( project => $root, rule => 'monitor-output',
        action => 'bridge-reminder', author => 'claude' );
    my $job = $tira->job_add( project => $root, schedule => 'monitor',
        command => 'a-poller', author => 'claude' );
    $tira->job_started( project => $root, id => $job->{id}, pid => 4242 );

    require Tira::CLI::Police;

    my @keys;
    for my $words ( 'the first thing it said', 'something completely different' ) {
        $tira->job_feed( project => $root, id => $job->{id}, lines => [$words] );

        my $result = $tira->police_pass( project => $root,
            store => Tira::CLI::Police::_police_store($root),
            world => Tira::CLI::Police::police_world(
                tira => $tira, project => $root ) );

        my ($said) = grep { ( $_->{rule} // '' ) eq 'monitor-output' }
          @{ $result->{violations} || [] };

        # non-empty is the whole claim: no finding at all would make the
        # comparison below vacuously equal and report this bug as fixed.
        ok( $said, "the pass produced a monitor-output finding for '$words'" )
          or next;

        like( $said->{detail} // '', qr/\Q$words\E/,
            'and the finding carries the words themselves' );

        push @keys, $fingerprint ? $fingerprint->($said) : '';

        # Drained by hand, since police_pass deliberately writes nothing - so
        # the second round starts from an empty queue the way a real pass leaves
        # it. Doing it here rather than through advance_monitor_output keeps
        # this block about the rule.
        $tira->job_output_drain( project => $root, id => $job->{id},
            count => 1, dropped => 0 );
    }

    isnt( $keys[0], $keys[1],
        'TWO PASSES CARRYING DIFFERENT WORDS ARE DIFFERENT LEDGER ENTRIES. '
          . 'Today they are the same one: monitor-output passes a sub_key to a '
          . 'three-parameter closure that discards it, so every finding it ever '
          . 'makes shares the key monitor-output|POLICY|"" - and the quiet '
          . 'ladder correctly reads that as one rule repeating itself' )
      or diag( "both findings keyed as: " . ( $keys[0] // 'undef' ) );
}

# --- the drain follows what was said, not what was meant ----------------------
#
# The half that makes this destructive rather than merely quiet, and the half a
# fix aimed only at the sub_key would leave in place.
#
# advance_monitor_output removes a monitor's lines from the record when the mark
# says `spoke`. `spoke` is computed from the same condition that CALLS $report,
# so it is 1 when $report returned early - a suspended rule, a declined card -
# and 1 when bridge_write later skipped the violation as quiet. Either way the
# words are gone and nobody saw them.

my $police = Suite::cli_source();

my ($drain) = $police =~ /(sub \s advance_monitor_output .*? \n \} )/xs;

ok( defined $drain && length $drain,
    'advance_monitor_output was extracted - the sub that takes a monitor\'s '
      . 'lines off the record' );

like( $drain // '', qr/spoke|announced|recorded/,
    'and it is the right region: it decides whether to drain from what the '
      . 'pass reported back' );

like( $drain // '', qr/\$result->\{violations\}/,
    'THE DRAIN CONSULTS WHAT WAS ANNOUNCED, not only what the rule meant to '
      . 'announce. Today its one guard is `next if !$mark->{spoke}`, and spoke '
      . 'is set from the same condition that CALLS $report - so it is true when '
      . '$report returned early, and true when bridge_write skipped the '
      . 'violation as quiet. The words came off the record either way, which is '
      . 'how a silenced announcement became destroyed output' );

like( $drain // '', qr/quiet/,
    'and a violation the bridge skipped as quiet does not count as announced - '
      . 'which is the case that actually happened here, every pass, for two '
      . 'days' );

# spoke STAYS. It answers a different question - did this monitor have anything
# to say at all - and removing it would drain a monitor that produced nothing.
# The fix is a second guard, not a replacement, and asserting that keeps a later
# tidy-up from collapsing the two.
like( $drain // '', qr/\$mark->\{spoke\}/,
    'and the "did it say anything" guard is still there, because the two ask '
      . 'different questions and only one of them is about the bridge' );

done_testing();

__END__

=head1 NAME

531-two-closures-one-name.t - a sub_key handed to a function that cannot take it

=head1 WHY

TKT-925. F<lib/Tira.pm> declares two closures named C<$report> with different
signatures. C<monitor-output> lives inside the three-parameter one and calls it
with five, passing a C<sub_key> that is discarded. The ledger fingerprint is
C<rule|policy|ref|sub_key>, so with neither a ref nor a sub_key every
C<monitor-output> finding a board ever makes is one ledger entry; the quiet
ladder marks every telling after the first as a repeat, and the bridge skips it.

Measured on this board: one C<monitor-output> line in three weeks, and it is the
first one ever made.

=head1 WHAT IS ASSERTED

That every C<$report> closure in the engine declares the same parameters - the
meta-guard, and the assertion that outlasts this card. That two findings
carrying different words are different ledger entries, and that a finding with a
sub_key is not the same entry as one without, which is what makes the dropped
argument observable. And that the drain no longer fires on "the rule intended to
speak".

=head1 WHAT IS NOT ASSERTED

The quiet ladder's own behaviour, which was correct on the information it had:
one ledger entry seen many times B<is> a rule repeating itself.

=cut
