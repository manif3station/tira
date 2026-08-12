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
my $root = File::Spec->catdir( $tmp, 'migration' );
my $tira = Tira->new( clock => sub { '2026-08-06T09:00:00Z' } );
$tira->create_project( name => 'Migration', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
my $sow = $tira->create_record( project => $root, type => 'sow', title => 'Legacy Jira SOW' );
my $epic = $tira->create_record( project => $root, type => 'epic', title => 'Epic', description => 'See Jira ABC-2' );
my $ticket = $tira->create_record(
    project => $root, type => 'ticket', title => 'Ticket', description => 'See Jira ABC-3',
    acceptance => ['Jira acceptance'],
);

my $export = $tira->export_records( project => $root );
is( $export->{count}, 3, 'export returns every record in one call' );
is_deeply( [ map { $_->{type} } @{ $export->{records} } ], [qw(epic sow ticket)], 'export includes all record types' );
ok( !( grep { !defined $_->{column} } @{ $export->{records} } ), 'export includes column state' );

my $hits = $tira->search( project => $root, text => 'Jira', field => 'description' );
is( $hits->{count}, 2, 'field-aware search counts exact field hits' );
is_deeply( [ map { $_->{field} } @{ $hits->{hits} } ], [qw(description description)], 'search reports matching field' );
like( $hits->{hits}[0]{value}, qr/Jira/, 'search reports matching value' );
is( $tira->search( project => $root, text => 'Jira', field => 'acceptance_criteria' )->{hits}[0]{field},
    'acceptance_criteria.0', 'field search traverses arrays' );
is( $tira->search( project => $root, text => 'missing', field => 'scope' )->{count}, 0,
    'field search traverses hashes and reports no false hit' );

my $preview = $tira->bulk_import(
    project => $root, dry_run => 1,
    changes => {
        $ticket->{ref} => { description => 'Local reference', acceptance_criteria => ['Local acceptance'] },
        $epic->{ref} => { title => 'Corrected epic' },
    },
);
is( $preview->{changed_records}, 2, 'import preview reports changed record count' );
ok( $preview->{dry_run}, 'import preview is marked dry-run' );
is( $tira->record_show( project => $root, ref => $ticket->{ref} )->{description}, 'See Jira ABC-3', 'dry-run changes nothing' );
my $applied = $tira->bulk_import( project => $root, changes => $preview->{requested_changes} );
is( $applied->{changed_records}, 2, 'import applies multiple records' );
is( $tira->record_show( project => $root, ref => $ticket->{ref} )->{description}, 'Local reference', 'import replaces scalar exactly' );
is_deeply( $tira->record_show( project => $root, ref => $ticket->{ref} )->{acceptance_criteria}, ['Local acceptance'], 'import replaces array exactly' );
eval { $tira->bulk_import( project => $root, changes => {
    $ticket->{ref} => { title => 'Must not persist' }, 'ZZZ-999' => { title => 'Missing' },
} ) };
like( $@, qr/not found/, 'invalid import set is rejected' );
isnt( $tira->record_show( project => $root, ref => $ticket->{ref} )->{title}, 'Must not persist', 'invalid import is atomic' );
for my $case (
    [ [], qr/JSON object/ ],
    [ { $ticket->{ref} => [] }, qr/must be a JSON object/ ],
    [ { $ticket->{ref} => { ref => 'NEW-1' } }, qr/not mutable/ ],
    [ { $ticket->{ref} => { labels => 'wrong type' } }, qr/incompatible/ ],
) {
    eval { $tira->bulk_import( project => $root, changes => $case->[0], dry_run => 1 ) };
    like( $@, $case->[1], 'import rejects unsafe input before writing' );
}
is( $tira->bulk_import( project => $root, changes => { $ticket->{ref} => { title => $ticket->{title} } } )->{changed_records},
    0, 'no-op import performs no write' );

my $replace = $tira->replace_records(
    project => $root, pattern => 'Jira', with => 'Local', field => 'title', dry_run => 1,
);
is( $replace->{changed_records}, 1, 'replace preview reports affected records' );
is( $tira->record_show( project => $root, ref => $sow->{ref} )->{title}, 'Legacy Jira SOW', 'replace dry-run changes nothing' );
$replace = $tira->replace_records( project => $root, pattern => 'Jira', with => 'Local', field => 'title' );
is( $tira->record_show( project => $root, ref => $sow->{ref} )->{title}, 'Legacy Local SOW', 'replace applies selected field' );
my $comment_for_replace = $tira->comment_add(
    project => $root, ref => $ticket->{ref}, author => 'ada', text => 'Jira nested comment',
);
my $nested_replace = $tira->replace_records(
    project => $root, pattern => 'Jira', with => 'Local', field => 'comments',
);
is( $nested_replace->{changed_records}, 1, 'replace traverses mutable arrays and hashes' );
is( $tira->comment_list( project => $root, ref => $ticket->{ref} )->[-1]{body}, 'Local nested comment',
    'nested replacement persists comment body' );
is( $tira->replace_records( project => $root, pattern => 'never-match', with => 'x' )->{changed_records},
    0, 'unrestricted no-match replacement performs no write' );
for my $case (
    [ { with => 'x' }, qr/pattern is required/ ],
    [ { pattern => 'x' }, qr/text is required/ ],
    [ { pattern => '[', with => 'x' }, qr/Invalid replacement pattern/ ],
    [ { pattern => 'x', with => 'y', field => 'gate_passing_log' }, qr/not mutable/ ],
) {
    eval { $tira->replace_records( project => $root, %{ $case->[0] } ) };
    like( $@, $case->[1], 'replace rejects unsafe arguments' );
}

my $gate = $tira->gate_add(
    project => $root, ref => $ticket->{ref}, gate => 'Migration', result => 'pass',
    details => 'Old Jira URL', author => 'ada',
);
is( $gate->{id}, 'GATE-001', 'gate receives stable ID' );
my $gate_note = $tira->gate_annotate(
    project => $root, ref => $ticket->{ref}, id => $gate->{id}, note => 'Use local docs', author => 'ada',
);
is( $gate_note->{note}, 'Use local docs', 'gate annotation is appended' );
is( $tira->gate_list( project => $root, ref => $ticket->{ref} )->[0]{details}, 'Old Jira URL', 'gate original remains unchanged' );

my $evidence = $tira->evidence_add(
    project => $root, ref => $ticket->{ref}, summary => 'Old Confluence URL', author => 'ada',
);
is( $evidence->{id}, 'EVD-001', 'evidence receives stable ID' );
my $evidence_note = $tira->evidence_annotate(
    project => $root, ref => $ticket->{ref}, id => $evidence->{id}, note => 'Use docs/evidence.md', author => 'ada',
);
is( $evidence_note->{note}, 'Use docs/evidence.md', 'evidence annotation is appended' );
is( $tira->evidence_list( project => $root, ref => $ticket->{ref} )->[0]{summary}, 'Old Confluence URL', 'evidence original remains unchanged' );
eval { $tira->gate_annotate( project => $root, ref => $ticket->{ref}, id => 'GATE-001', note => '' ) };
like( $@, qr/note is required/, 'empty annotation is rejected' );
eval { $tira->evidence_annotate( project => $root, ref => $ticket->{ref}, id => 'EVD-999', note => 'x' ) };
like( $@, qr/not found/, 'unknown annotation target is rejected' );

local $ENV{TIRA_HOME} = $root;
my $import_file = File::Spec->catfile( $tmp, 'changes.json' );
open my $import_fh, '>:raw', $import_file or die $!;
print {$import_fh} Cpanel::JSON::XS->new->canonical->utf8->encode({ $ticket->{ref} => { title => 'CLI preview title' } });
close $import_fh;
my $array_file = File::Spec->catfile( $tmp, 'array.json' );
open my $array_fh, '>:raw', $array_file or die $!;
print {$array_fh} '["Alias replacement"]';
close $array_fh;
for my $case (
    [ export => [], qr/"count"\s*:\s*3/ ],
    [ search => [ '--text', 'Local', '--field', 'title' ], qr/"field"\s*:\s*"title"/ ],
    [ 'record.list', [ '--full' ], qr/"column"/ ],
    [ import => [ '--file', $import_file, '--dry-run' ], qr/"dry_run"\s*:\s*true/ ],
    [ replace => [ '--pattern', 'Local', '--with', 'Project', '--field', 'title', '--dry-run' ], qr/"changed_records"/ ],
    [ 'gate.annotate', [ '--ref', $ticket->{ref}, '--id', 'GATE-001', '--note', 'CLI gate note', '--author', 'ada' ], qr/CLI gate note/ ],
    [ 'evidence.annotate', [ '--ref', $ticket->{ref}, '--id', 'EVD-001', '--note', 'CLI evidence note', '--author', 'ada' ], qr/CLI evidence note/ ],
    [ 'record.update', [ '--ref', $ticket->{ref}, '--problem-or-feature', 'Alias problem', '--acceptance-criteria', 'Alias criterion' ], qr/"problem_or_feature"\s*:\s*"Alias problem"/ ],
    [ 'record.update', [ '--ref', $ticket->{ref}, '--set-acceptance-criteria', $array_file ], qr/Alias replacement/ ],
) {
    my ( $command, $argv, $expected ) = @{$case};
    $ENV{TIRA_HOME} = $root;
    my ( $stdout, $stderr ) = ('', '');
    open my $out, '>', \$stdout or die $!;
    open my $err, '>', \$stderr or die $!;
    local *STDOUT = $out;
    local *STDERR = $err;
    is( Tira::CLI->run( command => $command, type => $command =~ /^record\./ ? 'ticket' : undef,
        argv => [ @{$argv}, '-o', 'json' ] ), 0, "$command CLI succeeds" );
    like( $stdout, $expected, "$command CLI returns expected data" );
    is( $stderr, '', "$command CLI has no stderr" );
}

my $multi = $tira->create_record(
    project => $root, type => 'ticket', title => 'Multi-field probe',
    description => 'legacy instruction', bdd => ['legacy BDD'], atdd => ['legacy ATDD'],
);
$tira->comment_add( project => $root, ref => $multi->{ref}, author => 'ada', text => 'legacy historical comment' );
my $unscoped = $tira->search( project => $root, text => 'legacy', type => 'ticket' );
is( ref($unscoped), 'HASH', 'unscoped search returns the standard object envelope' );
ok( exists $unscoped->{hits} && exists $unscoped->{count}, 'unscoped search exposes hits and count' );
my $multi_hits = $tira->search(
    project => $root, text => 'legacy', fields => [qw(description bdd atdd)], type => 'ticket',
);
is_deeply( [ map { $_->{field} } @{ $multi_hits->{hits} } ],
    [ 'description', 'bdd.0', 'atdd.0' ], 'search accumulates all named fields' );
my $multi_preview = $tira->replace_records(
    project => $root, pattern => 'legacy', with => 'current',
    fields => [qw(description bdd atdd)], type => 'ticket', dry_run => 1,
);
is_deeply( [ map { $_->{field} } @{ $multi_preview->{changes} } ],
    [qw(description bdd atdd)], 'replace dry-run groups changes by every named field' );
$tira->replace_records(
    project => $root, pattern => 'legacy', with => 'current',
    fields => [qw(description bdd atdd)], type => 'ticket',
);
is( $tira->search( project => $root, text => 'legacy', field => 'comments', type => 'ticket' )->{count},
    1, 'replace leaves an unnamed comment field untouched' );

my ( $multi_out, $multi_err ) = ('', '');
{
    $ENV{TIRA_HOME} = $root;
    open my $out, '>', \$multi_out or die $!;
    open my $err, '>', \$multi_err or die $!;
    local *STDOUT = $out;
    local *STDERR = $err;
    is( Tira::CLI->run( command => 'search', argv => [
        '--text', 'current', '--field', 'description', '--field', 'atdd', '-o', 'json',
    ] ), 0, 'CLI accepts repeated field scopes' );
}
is( $multi_err, '', 'repeated-field CLI search has no stderr' );
is_deeply( [ map { $_->{field} } @{ decode_json($multi_out)->{hits} } ],
    [ 'description', 'atdd.0' ], 'CLI repeated fields accumulate rather than overwrite' );

done_testing;

__END__

=head1 NAME

13-migration-tools.t - Migration-scale Tira read and correction tools

=head1 DESCRIPTION

Proves one-call export, full list compatibility, field-aware search, dry-run
bulk import and replacement, and append-only gate/evidence annotations.

=cut
