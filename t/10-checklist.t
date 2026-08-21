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

    my $entry = $tira->checklist_add(
        project => $root, ref => $record->{ref}, item => 'Review requirements', status => 'To Do',
    );
    is( $entry->{id}, 'CHK-001', "$type first checklist ID is stable" );
    is( $entry->{item}, 'Review requirements', "$type stores checklist item" );
    is( $entry->{status}, 'To Do', "$type stores checklist status" );

    $entry = $tira->checklist_update(
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
    [ add => { item => 'Test', status => '' }, qr/status is required/i ],
    [ update => { id => 'CHK-999', status => 'Done', command => ['x'], proof => ['y'] }, qr/not found/i ],
    [ update => { id => 'CHK-001' }, qr/item or status/i ],
) {
    my ( $action, $args, $error ) = @{$case};
    my $method = "checklist_$action";
    eval { $tira->$method( project => $root, ref => $ticket->{ref}, %{$args} ) };
    like( $@, $error, "checklist $action validates input" );
}

$tira->checklist_add( project => $root, ref => $ticket->{ref}, item => 'Build', status => 'Open' );
my $updated = $tira->checklist_update(
    project => $root, ref => $ticket->{ref}, id => 'CHK-001', item => 'Build release', status => 'Done',
    command => ['make release'], proof => ['build succeeded'],
);
is( $updated->{item}, 'Build release', 'checklist update can replace item and status together' );
like( $tira->format_output( $tira->record_show( project => $root, ref => $ticket->{ref} ), output => 'human', project => $root ),
    qr/- \[Done\] Build release/, 'human record output renders checklist status and item' );

local $ENV{TIRA_HOME} = $root;
my ( $stdout, $stderr ) = ('', '');
{
    open my $out, '>', \$stdout or die $!;
    open my $err, '>', \$stderr or die $!;
    local *STDOUT = $out;
    local *STDERR = $err;
    is( Tira::CLI->run( command => 'checklist.add', argv => [ '--ref', $ticket->{ref}, '--item', 'Deploy', '--status', 'Ready', '-o', 'json' ] ), 0,
        'checklist add CLI succeeds' );
}
like( $stdout, qr/"item"\s*:\s*"Deploy"/, 'checklist add CLI returns entry' );
is( $stderr, '', 'checklist add CLI has no stderr' );

for my $case (
    [ 'checklist.update', [ '--ref', $ticket->{ref}, '--id', 'CHK-002', '--status', 'Done',
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

done_testing;

__END__

=head1 NAME

10-checklist.t - Symmetric SOW, epic, and ticket checklist behavior

=head1 DESCRIPTION

Proves checklist defaults, item/status validation, stable IDs, updates, lists,
human rendering, and CLI dispatch across the shared record model.

=cut
