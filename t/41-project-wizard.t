#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );

sub answers {
    my ($script) = @_;
    open my $fh, '<', \$script or die $!;
    return $fh;
}

sub run_wizard {
    my ( $script, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run(
        command => 'onboard', argv => \@argv, input => answers($script),
    );
    return ( $status, $out, $err );
}

my $home = File::Spec->catdir( $tmp, 'guided' );
my ( $status, $out, $err ) = run_wizard( <<"ANSWERS", '-o', 'json' );
MT5
$home
K-Bot, Michael
M5S
M5E
M5T
y
Backlog, Planning, Documenting, Ready, In Progress, Vulnerability Scanner, Unit Testing, E2E Testing, Done / Release
y
ANSWERS
is( $status, 0, 'the guided flow completes' );
like( $out, qr/Project name/i, 'it asks for the project name' );
like( $out, qr/same columns/i, 'it asks whether the boards share one column set' );

my $tira = Tira->new;
is( $tira->project_show( project => $home )->{name}, 'MT5', 'the answers create the project' );
is_deeply( [ map { $_->{id} } @{ $tira->person_list( project => $home ) } ],
    [ 'K-Bot', 'Michael' ], 'the members are added' );
is( $tira->board_refs( project => $home, type => 'sow' )->{prefix}, 'M5S', 'the sow prefix is set' );
is( $tira->board_refs( project => $home, type => 'ticket' )->{prefix}, 'M5T', 'the ticket prefix is set' );
for my $type (qw(sow epic ticket)) {
    is_deeply(
        [ map { $_->{name} } @{ $tira->column_list( project => $home, type => $type ) } ],
        [ qw(backlog planning documenting ready in-progress
             vulnerability-scanner unit-testing e2e-testing done-release discard) ],
        "$type gets the shared column set"
    );
}

# Answering "no" to the shared-columns question must actually mean something.
my $split = File::Spec->catdir( $tmp, 'split' );
( $status, $out, $err ) = run_wizard( <<"ANSWERS", '-o', 'json' );
Split
$split
ada
SPS
SPE
SPT
n
Shaping
Breaking Down
Doing, Reviewing
y
ANSWERS
is( $status, 0, 'the per-board flow completes' );
is_deeply( [ map { $_->{name} } @{ $tira->column_list( project => $split, type => 'sow' ) } ],
    [qw(backlog shaping discard)], 'the sow board gets its own columns' );
is_deeply( [ map { $_->{name} } @{ $tira->column_list( project => $split, type => 'epic' ) } ],
    [qw(backlog breaking-down discard)], 'the epic board gets its own columns' );
is_deeply( [ map { $_->{name} } @{ $tira->column_list( project => $split, type => 'ticket' ) } ],
    [qw(backlog doing reviewing discard)], 'the ticket board gets its own columns' );

# Bad answers re-ask rather than abort.
my $retry = File::Spec->catdir( $tmp, 'retry' );
( $status, $out, $err ) = run_wizard( <<"ANSWERS", '-o', 'json' );

Retried
$retry
ada
lower
RTS
RTE
RTT
y
Doing
y
ANSWERS
is( $status, 0, 'the flow survives bad answers' );
like( $out, qr/must start with a capital|Invalid/i, 'a bad prefix explains itself' );
is( $tira->project_show( project => $retry )->{name}, 'Retried', 'the retried answers are used' );
is( $tira->board_refs( project => $retry, type => 'sow' )->{prefix}, 'RTS', 'the corrected prefix is stored' );

# Declining the confirmation creates nothing.
my $declined = File::Spec->catdir( $tmp, 'declined' );
( $status, $out, $err ) = run_wizard( <<"ANSWERS" );
Declined
$declined
ada
DCS
DCE
DCT
y
Doing
n
ANSWERS
is( $status, 1, 'declining exits 1' );
ok( !-e $declined, 'declining creates nothing' );

# End of input aborts cleanly.
my $abandoned = File::Spec->catdir( $tmp, 'abandoned' );
( $status, $out, $err ) = run_wizard("Abandoned\n$abandoned\n");
isnt( $status, 0, 'running out of input does not report success' );
ok( !-e $abandoned, 'an abandoned flow creates nothing' );

# Flags pre-fill the questions they answer.
my $prefilled = File::Spec->catdir( $tmp, 'prefilled' );
( $status, $out, $err ) = run_wizard( <<"ANSWERS", '--name', 'Prefilled', '--sow-prefix', 'PFS', '-o', 'json' );

$prefilled
ada

PFE
PFT
y
Doing
y
ANSWERS
is( $status, 0, 'a partly-filled command line completes through the flow' );
is( $tira->project_show( project => $prefilled )->{name}, 'Prefilled', 'the flag value is the default' );
is( $tira->board_refs( project => $prefilled, type => 'sow' )->{prefix}, 'PFS',
    'an answered prefix is not asked again destructively' );

# Every abandonment point must leave nothing behind, not just the first.
for my $case (
    [ "Stopped\n", 'the directory question' ],
    [ "Stopped\n$tmp/stop-a\n", 'the people question' ],
    [ "Stopped\n$tmp/stop-b\nada\n", 'the first prefix question' ],
    [ "Stopped\n$tmp/stop-c\nada\nSTA\nSTB\nSTC\n", 'the shared-columns question' ],
    [ "Stopped\n$tmp/stop-d\nada\nSTA\nSTB\nSTC\ny\n", 'the columns question' ],
    [ "Stopped\n$tmp/stop-e\nada\nSTA\nSTB\nSTC\nn\n", 'the first per-board columns question' ],
    [ "Stopped\n$tmp/stop-f\nada\nSTA\nSTB\nSTC\nn\nDoing\n", 'a later per-board columns question' ],
    [ "Stopped\n$tmp/stop-g\nada\nSTA\nSTB\nSTC\ny\nDoing\n", 'the confirmation' ],
) {
    my ( $script, $where ) = @{$case};
    my ( $stopped_status ) = run_wizard($script);
    is( $stopped_status, 2, "running out of input at $where aborts" );
}
ok( !-e "$tmp/stop-g", 'no abandoned run leaves a project behind' );

my ( $nonsense_status, $nonsense_out ) = run_wizard( <<"ANSWERS", '-o', 'json' );
Nonsense
$tmp/nonsense
ada
NSA
NSB
NSC
maybe
sure
y
Doing
y
ANSWERS
is( $nonsense_status, 0, 'an unclear yes/no answer is re-asked rather than guessed' );
like( $nonsense_out, qr/answer yes or no/i, 'and the re-ask says what is expected' );

# Flags for every question, accepted by pressing enter through the flow.
my $filled = File::Spec->catdir( $tmp, 'filled' );
( $status, $out, $err ) = run_wizard( "\n$filled\n\n\n\n\n\n\n\ny\n",
    '--name', 'Filled', '--members', 'ada, grace',
    '--columns', 'Doing, Shipped', '-o', 'json' );
is( $status, 0, 'a fully pre-filled flow completes on enter alone' );
is_deeply( [ map { $_->{id} } @{ $tira->person_list( project => $filled ) } ],
    [ 'ada', 'grace' ], 'the members flag becomes the default answer' );
is_deeply( [ map { $_->{name} } @{ $tira->column_list( project => $filled, type => 'sow' ) } ],
    [qw(backlog doing shipped discard)], 'the columns flag becomes the default answer' );

my $per_board = File::Spec->catdir( $tmp, 'per-board' );
( $status, $out, $err ) = run_wizard( "\n$per_board\nada\n\n\n\nn\n\n\n\ny\n",
    '--name', 'PerBoard', '--sow-columns', 'Shaping',
    '--epic-columns', 'Breaking Down', '--ticket-columns', 'Doing', '-o', 'json' );
is( $status, 0, 'per-board column flags complete on enter alone' );
is_deeply( [ map { $_->{name} } @{ $tira->column_list( project => $per_board, type => 'epic' ) } ],
    [qw(backlog breaking-down discard)], 'each per-board flag becomes its own default answer' );

# project.new itself must never prompt: it is what scripts and agents call.
( my $bare_status, $out, $err ) = do {
    my ( $o, $e ) = ( '', '' );
    open my $so, '>', \$o or die $!;
    open my $se, '>', \$e or die $!;
    local *STDOUT = $so;
    local *STDERR = $se;
    my $s = Tira::CLI->run( command => 'project.new', argv => ['-o', 'json'] );
    ( $s, $o, $e );
};
is( $bare_status, 2, 'a bare project.new exits 2 instead of ever waiting for input' );
like( $err, qr/name/i, 'and says what was missing' );

done_testing;

__END__

=head1 NAME

41-project-wizard.t - DD-448 tira.onboard guided setup

=head1 DESCRIPTION

Proves the guided question-and-answer flow: it asks the owner's own
questions, creates the project from the answers, applies per-board
column sets when the boards do not share one, re-asks on invalid input,
uses flags as defaults, exits 1 without creating anything when the
confirmation is declined, aborts on end of input, and, most
importantly for scripts and agents, never waits for input when
standard input is not a terminal.

=cut
