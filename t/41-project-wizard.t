#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
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

    # Pin the coding-agent seam so this proves the wizard, not whatever
    # happens to be installed on the machine running it.
    no warnings 'redefine';
    local *Tira::CLI::_agent_available = sub { 0 };
    my $status = Tira::CLI->run(
        command => 'onboard', argv => \@argv, input => answers($script),
    );
    return ( $status, $out, $err );
}

my $home = File::Spec->catdir( $tmp, 'guided' );
my ( $status, $out, $err ) = run_wizard( <<"ANSWERS", '-o', 'json' );
$home
MT5
K-Bot, Michael
M5S
M5E
M5T
y
Backlog, Planning, Documenting, Ready, In Progress, Vulnerability Scanner, Unit Testing, E2E Testing, Done / Release

single
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
$split
Split
ada
SPS
SPE
SPT
n
Shaping
Breaking Down
Doing, Reviewing

single
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
$retry

Retried
ada
lower
RTS
RTE
RTT
y
Doing

single
y
ANSWERS
is( $status, 0, 'the flow survives bad answers' );
like( $out, qr/must start with a capital|Invalid/i, 'a bad prefix explains itself' );
is( $tira->project_show( project => $retry )->{name}, 'Retried', 'the retried answers are used' );
is( $tira->board_refs( project => $retry, type => 'sow' )->{prefix}, 'RTS', 'the corrected prefix is stored' );

# Declining the confirmation creates nothing.
my $declined = File::Spec->catdir( $tmp, 'declined' );
( $status, $out, $err ) = run_wizard( <<"ANSWERS" );
$declined
Declined
ada
DCS
DCE
DCT
y
Doing

single
n
ANSWERS
is( $status, 1, 'declining exits 1' );
ok( !-e $declined, 'declining creates nothing' );

# End of input aborts cleanly.
my $abandoned = File::Spec->catdir( $tmp, 'abandoned' );
( $status, $out, $err ) = run_wizard("$abandoned\nAbandoned\n");
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

single
y
ANSWERS
is( $status, 0, 'a partly-filled command line completes through the flow' );
is( $tira->project_show( project => $prefilled )->{name}, 'Prefilled', 'the flag value is the default' );
is( $tira->board_refs( project => $prefilled, type => 'sow' )->{prefix}, 'PFS',
    'an answered prefix is not asked again destructively' );

# Every abandonment point must leave nothing behind, not just the first.
for my $case (
    [ "", 'the directory question' ],
    [ "$tmp/stop-a\n", 'the name question' ],
    [ "$tmp/stop-b\nStopped\n", 'the people question' ],
    [ "$tmp/stop-c\nStopped\nada\n", 'the first prefix question' ],
    [ "$tmp/stop-d\nStopped\nada\nSTA\nSTB\nSTC\n", 'the shared-columns question' ],
    [ "$tmp/stop-e\nStopped\nada\nSTA\nSTB\nSTC\ny\n", 'the columns question' ],
    [ "$tmp/stop-f\nStopped\nada\nSTA\nSTB\nSTC\nn\n", 'the first per-board columns question' ],
    [ "$tmp/stop-h\nStopped\nada\nSTA\nSTB\nSTC\nn\nDoing\n", 'a later per-board columns question' ],
    [ "$tmp/stop-i\nStopped\nada\nSTA\nSTB\nSTC\ny\nDoing\n", 'the staleness question' ],
    [ "$tmp/stop-g\nStopped\nada\nSTA\nSTB\nSTC\ny\nDoing\n\n", 'the confirmation' ],
) {
    my ( $script, $where ) = @{$case};
    my ( $stopped_status ) = run_wizard($script);
    is( $stopped_status, 2, "running out of input at $where aborts" );
}
ok( !-e "$tmp/stop-g", 'no abandoned run leaves a project behind' );

my ( $nonsense_status, $nonsense_out ) = run_wizard( <<"ANSWERS", '-o', 'json' );
$tmp/nonsense
Nonsense
ada
NSA
NSB
NSC
maybe
sure
y
Doing

single
y
ANSWERS
is( $nonsense_status, 0, 'an unclear yes/no answer is re-asked rather than guessed' );
like( $nonsense_out, qr/answer yes or no/i, 'and the re-ask says what is expected' );

# An answer to the mode question that is neither of the two is re-asked rather
# than stored or guessed - the same treatment every other unclear answer gets.
# A wizard that quietly accepted "multi" would leave a project configured in a
# word nothing understands, which reads as set while behaving as unset.
my $unclear = File::Spec->catdir( $tmp, 'unclear-mode' );
my ( $mode_status, $mode_out ) = run_wizard( <<"ANSWERS", '-o', 'json' );
$unclear
Unclear
ada
UNS
UNE
UNT
y
Backlog, Done

multi
chain
y
ANSWERS
is( $mode_status, 0, 'an answer that is neither kind is re-asked rather than guessed' );
like( $mode_out, qr/Answer with single or chain/,
    'and the re-ask says what the two answers are' );
is( $tira->project_mode( project => $unclear ), 'chain',
    'and the answer that follows is the one that is kept' );

# TKT-555: re-running onboarding against a project already set to chain
# mode should show that as the mode question's default, the same way
# every other field's current value is offered - _wizard_defaults must
# actually carry it for _project_wizard's existing lookup to find it.
is( Tira::CLI::_wizard_defaults( $tira, $unclear )->{mode}, 'chain',
    '_wizard_defaults carries the project\'s existing mode answer' );

# TKT-556: the "Do all three boards use the same columns?" question must
# default to whatever the existing project actually has, not a hardcoded
# yes - _wizard_defaults already computes column identity across boards
# (it is exactly what decides whether the shared `columns` key gets set),
# so that fact needs to be exposed for _project_wizard's yes/no default.
my $mismatched = File::Spec->catdir( $tmp, 'mismatched-columns' );
$tira->project_new(
    dir => $mismatched, name => 'Mismatched', sow_columns => 'Draft, Sent',
    epic_columns => 'Planning, Building', ticket_columns => 'Todo, Doing, Done',
);
is( Tira::CLI::_wizard_defaults( $tira, $mismatched )->{columns_shared}, 0,
    '_wizard_defaults reports columns as not shared when the boards genuinely differ' );

my $matched = File::Spec->catdir( $tmp, 'matched-columns' );
$tira->project_new( dir => $matched, name => 'Matched', columns => 'Doing, Done' );
is( Tira::CLI::_wizard_defaults( $tira, $matched )->{columns_shared}, 1,
    '_wizard_defaults reports columns as shared when every board genuinely matches' );

# Flags for every question, accepted by pressing enter through the flow.
my $filled = File::Spec->catdir( $tmp, 'filled' );
( $status, $out, $err ) = run_wizard( "$filled\n\n\n\n\n\n\n\n\n\ny\n",
    '--name', 'Filled', '--members', 'ada, grace',
    '--columns', 'Doing, Shipped', '-o', 'json' );
is( $status, 0, 'a fully pre-filled flow completes on enter alone' );
is_deeply( [ map { $_->{id} } @{ $tira->person_list( project => $filled ) } ],
    [ 'ada', 'grace' ], 'the members flag becomes the default answer' );
is_deeply( [ map { $_->{name} } @{ $tira->column_list( project => $filled, type => 'sow' ) } ],
    [qw(backlog doing shipped discard)], 'the columns flag becomes the default answer' );

my $per_board = File::Spec->catdir( $tmp, 'per-board' );
( $status, $out, $err ) = run_wizard( "$per_board\n\nada\n\n\n\nn\n\n\n\n\n\ny\n",
    '--name', 'PerBoard', '--sow-columns', 'Shaping',
    '--epic-columns', 'Breaking Down', '--ticket-columns', 'Doing', '-o', 'json' );
is( $status, 0, 'per-board column flags complete on enter alone' );
is_deeply( [ map { $_->{name} } @{ $tira->column_list( project => $per_board, type => 'epic' ) } ],
    [qw(backlog breaking-down discard)], 'each per-board flag becomes its own default answer' );

# The owner's report: a tilde typed at the directory question must mean home,
# not a directory literally named '~'.
{
    local $ENV{HOME} = $tmp;
    my ( $tilde_status ) = run_wizard( <<"ANSWERS", '-o', 'json' );
~/under-home
Tilde home
ada
THS
THE
THT
y
Doing

single
y
ANSWERS
    is( $tilde_status, 0, 'a tilde answer is accepted' );
    ok( -d File::Spec->catdir( $tmp, 'under-home', '.tira' ),
        'the project is created under the home directory' );
    ok( !-e File::Spec->catdir( $tmp, '~' ), 'and nothing named ~ is created' );
}

# Pressing enter past the people question means "none", not an empty name.
{
    my $nobody = File::Spec->catdir( $tmp, 'nobody' );
    my ( $skip_status ) = run_wizard( <<"ANSWERS", '-o', 'json' );
$nobody
Nobody

NBS
NBE
NBT
y
Doing

single
y
ANSWERS
    is( $skip_status, 0, 'skipping the people question is allowed' );
    is( scalar @{ Tira->new->person_list( project => $nobody ) }, 0, 'and adds nobody' );
}

# Project.new itself must never prompt: it is what scripts and agents call.
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

41-project-wizard.t - tira.onboard guided setup

=head1 DESCRIPTION

Proves the guided question-and-answer flow: it asks the owner's own
questions, creates the project from the answers, applies per-board
column sets when the boards do not share one, re-asks on invalid input,
uses flags as defaults, exits 1 without creating anything when the
confirmation is declined, aborts on end of input, and, most
importantly for scripts and agents, never waits for input when
standard input is not a terminal.

=cut
