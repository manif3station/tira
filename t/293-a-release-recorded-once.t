#!/usr/bin/env perl
# Recording a passed gate took three commands - gate.add, evidence.add,
# <type>.update --fix-version - every time this project shipped a release of
# its own, and forgetting one of them was caught only by a later refusal:
# TKT-288 closed with no gate and no fix_version, TKT-311 reached done with
# no gate recorded, TKT-334 needed evidence added after the push gate
# refused it. Measured across five cards on 2026-08-17: the identical tail
# ran on every one of them, 30 recording calls where 5 would do. TKT-345.
#
# What this does not touch: column moves. Walking the gates a card passes
# through is the discipline the push gate enforces, not paperwork a verb
# should shortcut - so release.record writes what a passed gate needs and
# leaves the card exactly where it was.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-19T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Released', dir => $root, members => ['claude'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'RLS', epic_prefix => 'RLE', ticket_prefix => 'RLT',
);

sub run {
    my (@argv) = @_;
    my $command = shift @argv;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            $ENV{TIRA_AUTHOR} = 'claude';
            Tira::CLI->run( command => $command, argv => [@argv], tira => $tira );
        };
    };
    return ( $status, $out . $err );
}

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Ships today' );
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'verify' );

# --- one command, everything a passed gate needs ---------------------------

my ( $status, $out ) = run(
    'release.record', '--ref', $card->{ref},
    '--gate', 'Release gate', '--result', 'pass', '--details', 'Suite green, 100% coverage',
    '--evidence', 'Full suite run, 6540 tests, 100% coverage on all three modules',
    '--fix-version', '3.01', '-o', 'json',
);
is( $status, 0, 'release.record succeeds with everything it needs' );

my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
is( scalar @{ $shown->{gate_passing_log} }, 1, 'one gate entry was written' );
is( $shown->{gate_passing_log}[0]{gate}, 'Release gate', 'naming the gate that was recorded' );
is( $shown->{gate_passing_log}[0]{result}, 'pass', 'and the result' );
is( scalar @{ $shown->{evidence} }, 1, 'one evidence entry was written' );
is( $shown->{evidence}[0]{summary}, 'Full suite run, 6540 tests, 100% coverage on all three modules',
    'carrying the evidence text' );
is( $shown->{fix_version}, '3.01', 'and the fix version was set' );

# --- column moves are untouched ---------------------------------------------

is( $shown->{column}, 'verify', 'release.record left the card exactly where it was' );

# --- anything it cannot be told is refused, not defaulted -------------------

{
    my $second = $tira->create_record( project => $root, type => 'ticket', title => 'Missing its version' );
    my ( $refused_status, $refused_out ) = run(
        'release.record', '--ref', $second->{ref},
        '--gate', 'Release gate', '--result', 'pass', '--details', 'Suite green',
        '--evidence', 'Ran it', '-o', 'json',
    );
    isnt( $refused_status, 0, 'omitting --fix-version is refused rather than guessed' );
    like( $refused_out, qr/[Ff]ix version/, 'naming what was missing' );

    my $unaffected = $tira->record_show( project => $root, ref => $second->{ref} );
    is( scalar @{ $unaffected->{gate_passing_log} }, 0,
        'and nothing was written - not even the gate the call also carried' );
    is( scalar @{ $unaffected->{evidence} }, 0, 'nor the evidence' );
}

{
    my $third = $tira->create_record( project => $root, type => 'ticket', title => 'Missing evidence' );
    my ( $refused_status, $refused_out ) = run(
        'release.record', '--ref', $third->{ref},
        '--gate', 'Release gate', '--result', 'pass', '--details', 'Suite green',
        '--fix-version', '3.01', '-o', 'json',
    );
    isnt( $refused_status, 0, 'omitting --evidence is refused rather than guessed' );
    like( $refused_out, qr/[Ee]vidence/, 'naming what was missing' );
}

# --- the individual commands keep working exactly as they do today ---------

{
    my $fourth = $tira->create_record( project => $root, type => 'ticket', title => 'Recorded by hand' );
    $tira->gate_add( author => 'claude', project => $root, ref => $fourth->{ref},
        gate => 'Release gate', result => 'pass', details => 'By hand' );
    $tira->evidence_add( author => 'claude', project => $root, ref => $fourth->{ref}, summary => 'By hand' );
    $tira->record_update( author => 'claude', project => $root, ref => $fourth->{ref}, fix_version => '3.01' );
    my $shown_fourth = $tira->record_show( project => $root, ref => $fourth->{ref} );
    is( $shown_fourth->{fix_version}, '3.01', 'gate.add, evidence.add and update --fix-version still work unchanged' );
}

# --- TKT-561: a whole batch that shipped together records in one call ------
{
    my $fifth = $tira->create_record( project => $root, type => 'ticket', title => 'First of a pair' );
    my $sixth = $tira->create_record( project => $root, type => 'ticket', title => 'Second of a pair' );
    my ( $status, $out ) = run(
        'release.record', '--ref', $fifth->{ref}, '--ref', $sixth->{ref},
        '--gate', 'Release gate', '--result', 'pass', '--details', 'Suite green',
        '--evidence', 'Ran it', '--fix-version', '3.02', '-o', 'json',
    );
    is( $status, 0, 'release.record accepts more than one --ref in a single call' );
    for my $ref ( $fifth->{ref}, $sixth->{ref} ) {
        my $shown = $tira->record_show( project => $root, ref => $ref );
        is( scalar @{ $shown->{gate_passing_log} }, 1, "$ref got the gate entry" );
        is( scalar @{ $shown->{evidence} }, 1, "$ref got the evidence entry" );
        is( $shown->{fix_version}, '3.02', "$ref got the fix version" );
    }
}

# --- TKT-569: one bad ref must not strand the rest --------------------------
#
# The batch loop promised independence in its own comment and did not have
# it: the first ref gate_add refused threw straight out, so refs before it
# were written, refs after it were not, and the caller heard only about the
# bad one. Proved on a scratch board before this test existed - RT-001 came
# back with gates=1 and fix_version=1.0 while RT-002 had nothing at all.
# That matters here more than in most commands, because these are the very
# fields the push gate reads back.

{
    my $good_one = $tira->create_record( project => $root, type => 'ticket', title => 'First of a batch' );
    my $good_two = $tira->create_record( project => $root, type => 'ticket', title => 'Last of a batch' );

    my $result = eval {
        $tira->release_record(
            project => $root, author => 'claude',
            refs => [ $good_one->{ref}, 'RLT-999', $good_two->{ref} ],
            gate => 'Release gate', result => 'pass', details => 'Suite green',
            evidence => 'Ran it', fix_version => '3.05',
        );
    };
    ok( !$@, 'a batch with one bad ref does not throw away the whole call' ) or diag($@);

    for my $ref ( $good_one->{ref}, $good_two->{ref} ) {
        my $shown = $tira->record_show( project => $root, ref => $ref );
        is( scalar @{ $shown->{gate_passing_log} }, 1, "$ref was recorded despite the bad ref beside it" );
        is( $shown->{fix_version}, '3.05', "$ref carries the fix version too" );
    }

    is_deeply( [ map { $_->{ref} } @{ $result->{refused} // [] } ], ['RLT-999'],
        'and the ref that could not be written is reported rather than swallowed' );
    like( $result->{refused}[0]{error}, qr/RLT-999/, 'with the reason it was refused' );
}

{
    # Nothing recorded at all is still a failure: a call that achieved
    # nothing should not look like a success with a footnote.
    my $nothing = eval {
        $tira->release_record(
            project => $root, author => 'claude',
            refs => [ 'RLT-997', 'RLT-998' ],
            gate => 'Release gate', result => 'pass', details => 'Suite green',
            evidence => 'Ran it', fix_version => '3.06',
        );
    };
    ok( !$nothing, 'a batch in which every ref fails does not return a result' );
    like( $@, qr/RLT-99[78]/, 'and says which refs it could not write' );
}

# --- the call count a release takes, before and after -----------------------
#
# Not a Test::More assertion - the measurement itself, recorded so the claim
# this ticket makes is checked the same way its evidence was: by counting.
my $before = 3;    # gate.add, evidence.add, <type>.update --fix-version
my $after  = 1;    # release.record
cmp_ok( $after, '<', $before, 'one command replaces three' );

done_testing;

__END__

=head1 NAME

293-a-release-recorded-once.t - one command for what three did

=head1 DESCRIPTION

Recording a passed gate took gate.add, evidence.add and <type>.update
--fix-version, separately, on every release - and forgetting one of them
was caught only by a later refusal, three times on this project's own
board. release.record writes all three in one command, refusing rather
than defaulting if anything it needs is missing, and never moves a column -
that discipline stays manual. The individual commands keep working exactly
as they did.

=cut
