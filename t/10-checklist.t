#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'checklists' );
my $tira = Tira->new( clock => sub { '2026-08-05T15:00:00Z' } );
$tira->create_project( name => 'Checklists', dir => $root );

for my $type (qw(sow epic ticket)) {
    my $record = $tira->create_record( project => $root, type => $type, title => "Checklist $type" );
    is_deeply( $record->{checklist}, [], "$type starts with an empty checklist" );

    my $entry = $tira->checklist_add( author => 'claude',
        project => $root, ref => $record->{ref}, item => 'Review requirements', status => 'To Do',
    );
    is( $entry->{id}, 'CHK-001', "$type first checklist ID is stable" );
    is( $entry->{item}, 'Review requirements', "$type stores checklist item" );
    is( $entry->{status}, 'To Do', "$type stores checklist status" );

    $entry = $tira->checklist_update( author => 'claude',
        project => $root, ref => $record->{ref}, id => $entry->{id}, status => 'Done',
        command => ['reviewed'], proof => ['looked it over'],
    );
    is( $entry->{item}, 'Review requirements', "$type update preserves omitted item" );
    is( $entry->{status}, 'Done', "$type updates checklist status" );
    is_deeply( $tira->checklist_list( project => $root, ref => $record->{ref} ), [$entry], "$type lists checklist" );
}

my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Validation' );
for my $case (
    [ add => { item => '', status => 'Todo' }, qr/item is required/i ],
    [ update => { id => 'CHK-999', status => 'Done', command => ['x'], proof => ['y'] }, qr/not found/i ],
    [ update => { id => 'CHK-001' }, qr/item or status/i ],
) {
    my ( $action, $args, $error ) = @{$case};
    my $method = "checklist_$action";
    eval { $tira->$method( project => $root, ref => $ticket->{ref}, author => 'claude', %{$args} ) };
    like( $@, $error, "checklist $action validates input" );
}

# --- TKT-574: checklist_add's status defaults rather than being required ---
#
# 'To Do' is the only sensible status for a newly-added item - one created
# already Done has nothing left to prove and the checklist gates would have
# nothing to mark - so defaulting it loses no expressiveness, and an
# explicit --status still wins unchanged.

{
    my $defaulted = $tira->checklist_add( author => 'claude',
        project => $root, ref => $ticket->{ref}, item => 'No status given' );
    is( $defaulted->{status}, 'To Do',
        'checklist_add with no --status at all defaults to To Do' );

    my $empty_string = $tira->checklist_add( author => 'claude',
        project => $root, ref => $ticket->{ref}, item => 'Empty status string', status => '' );
    is( $empty_string->{status}, 'To Do',
        'and an explicit empty string is treated the same as omitting it' );

    my $explicit = $tira->checklist_add( author => 'claude',
        project => $root, ref => $ticket->{ref}, item => 'Explicit status', status => 'pending' );
    is( $explicit->{status}, 'pending',
        'while an explicit --status still wins, unchanged' );
}

$tira->checklist_add( author => 'claude', project => $root, ref => $ticket->{ref}, item => 'Build', status => 'pending' );
my $updated = $tira->checklist_update( author => 'claude',
    project => $root, ref => $ticket->{ref}, id => 'CHK-001', item => 'Build release', status => 'Done',
    command => ['make release'], proof => ['build succeeded'],
);
is( $updated->{item}, 'Build release', 'checklist update can replace item and status together' );
like( $tira->format_output( $tira->record_show( project => $root, ref => $ticket->{ref} ), output => 'human', project => $root ),
    qr/- \[Done\] Build release/, 'human record output renders checklist status and item' );

local $ENV{TIRA_HOME} = $root;
local $ENV{TIRA_AUTHOR} = 'claude';
my ( $stdout, $stderr ) = ('', '');
{
    open my $out, '>', \$stdout or die $!;
    open my $err, '>', \$stderr or die $!;
    local *STDOUT = $out;
    local *STDERR = $err;
    is( Tira::CLI->run( command => 'checklist.add', argv => [ '--ref', $ticket->{ref}, '--item', 'Deploy', '--status', 'pending', '-o', 'json' ] ), 0,
        'checklist add CLI succeeds' );
}
like( $stdout, qr/"item"\s*:\s*"Deploy"/, 'checklist add CLI returns entry' );
is( $stderr, '', 'checklist add CLI has no stderr' );

for my $case (
    [ 'checklist.update', [ '--ref', $ticket->{ref}, '--id', 'CHK-002', '--status', 'Done', '--author', 'claude',
        '--command', 'ran deploy', '--proof', 'deployed ok', '-o', 'json' ], qr/"status"\s*:\s*"Done"/ ],
    [ 'checklist.list', [ '--ref', $ticket->{ref}, '-o', 'json' ], qr/"id"\s*:\s*"CHK-002"/ ],
) {
    my ( $command, $argv, $expected ) = @{$case};
    $ENV{TIRA_HOME} = $root;
    ($stdout, $stderr) = ('', '');
    open my $out, '>', \$stdout or die $!;
    open my $err, '>', \$stderr or die $!;
    local *STDOUT = $out;
    local *STDERR = $err;
    is( Tira::CLI->run( command => $command, argv => $argv ), 0, "$command CLI succeeds" );
    like( $stdout, $expected, "$command returns checklist data" );
    is( $stderr, '', "$command CLI has no stderr" );
}

# --- TKT-574: --checklist on create_record, symmetric across all three types
#
# A checklist item at creation is no heavier than any other list field
# these three record kinds already take at creation - a string plus a
# status, not a proof pair.

for my $type (qw(sow epic ticket)) {
    my $with = $tira->create_record( project => $root, type => $type,
        title => "Filed with items ($type)",
        checklist => [ 'First item', 'Second item', 'Third item' ] );
    is( scalar @{ $with->{checklist} }, 3,
        "$type create_record with --checklist creates all three items" );
    is_deeply( [ map { $_->{item} } @{ $with->{checklist} } ],
        [ 'First item', 'Second item', 'Third item' ],
        "$type checklist items land in the order given" );
    is_deeply( [ map { $_->{id} } @{ $with->{checklist} } ],
        [qw(CHK-001 CHK-002 CHK-003)],
        "$type checklist ids are sequential from CHK-001" );
    ok( !( grep { $_->{status} ne 'To Do' } @{ $with->{checklist} } ),
        "$type every item created via --checklist defaults to To Do" );

    my $without = $tira->create_record( project => $root, type => $type,
        title => "Filed with none ($type)" );
    is_deeply( $without->{checklist}, [],
        "$type create_record with no --checklist is unchanged - empty list" );
}

# A --checklist item is no less a checklist item than one added afterward -
# checklist_add refuses a whitespace-only one, and so must this path.
# Caught by Codex review: the first cut of --checklist stored '   ' verbatim.
for my $bad ( '', '   ' ) {
    eval {
        $tira->create_record( project => $root, type => 'ticket',
            title => 'Should not be created', checklist => [ 'Fine', $bad ] );
    };
    like( $@, qr/item is required/i,
        '--checklist refuses a whitespace-only/empty item the same as checklist_add does' );
}

# Marking an item done at creation-time speed still requires its own
# --command/--proof pair - TKT-574 adds items, it does not weaken the
# evidence rule TKT-958 already enforces on marking one done.
{
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Cannot skip the proof rule', checklist => ['Needs proof'] );
    eval {
        $tira->checklist_update( author => 'claude', project => $root,
            ref => $card->{ref}, id => 'CHK-001', status => 'Done' );
    };
    like( $@, qr/proof/i,
        'marking a --checklist-created item Done still refuses with no command/proof pair' );
}

# The CLI surface: ticket.create --checklist is repeatable, exactly like
# --key-detail and the other list flags this command already takes.
{
    local $ENV{TIRA_HOME} = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    my ( $out_text, $err_text ) = ('', '');
    open my $out, '>', \$out_text or die $!;
    open my $err, '>', \$err_text or die $!;
    local *STDOUT = $out;
    local *STDERR = $err;
    is( Tira::CLI->run( command => 'record.create', type => 'ticket',
        argv => [ '--title', 'CLI filed with items',
            '--checklist', 'First via CLI', '--checklist', 'Second via CLI',
            '-o', 'json' ] ), 0, 'ticket.create --checklist (repeated) CLI succeeds' );
    like( $out_text, qr/"item"\s*:\s*"First via CLI"/, 'first item reached the record' );
    like( $out_text, qr/"item"\s*:\s*"Second via CLI"/, 'and the second' );
    is( $err_text, '', 'ticket.create --checklist CLI has no stderr' );
}

# --checklist is refused on record.update, deliberately - it asks WHICH
# item to touch on an existing card, a question this flag cannot answer.
{
    local $ENV{TIRA_HOME} = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    my ( $out_text, $err_text ) = ('', '');
    open my $out, '>', \$out_text or die $!;
    open my $err, '>', \$err_text or die $!;
    local *STDOUT = $out;
    local *STDERR = $err;
    my $status = Tira::CLI->run( command => 'ticket.update',
        argv => [ '--ref', $ticket->{ref}, '--checklist', 'Should be refused' ] );
    isnt( $status, 0, 'ticket.update --checklist is refused rather than silently dropped' );
    like( $err_text, qr/checklist\.add/,
        'and the refusal names the command that actually adds a checklist item' );
}

done_testing;

__END__

=head1 NAME

10-checklist.t - Symmetric SOW, epic, and ticket checklist behavior

=head1 DESCRIPTION

Proves checklist defaults, item/status validation, stable IDs, updates, lists,
human rendering, and CLI dispatch across the shared record model.

=cut
