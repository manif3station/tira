#!/usr/bin/env perl

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use JSON::PP qw(decode_json);
use Test::More;

use lib 'lib';
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'matrix' );

sub cli {
    my ( $command, $type, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => $command, type => $type, argv => \@argv );
    return ( $status, $out, $err );
}

my ( $status, $out ) = cli( 'project.create', undef, '--name', 'Matrix', '--dir', $root, '-o', 'json' );
is( $status, 0, 'matrix project created' );
my @at = ( '--project', $root, '-o', 'json' );

( $status, $out ) = cli( 'project.show', undef, @at );
is( decode_json($out)->{name}, 'Matrix', 'project show dispatch' );
( $status, $out ) = cli( 'project.update', undef, '--name', 'Updated Matrix', @at );
is( decode_json($out)->{name}, 'Updated Matrix', 'project update dispatch' );

cli( 'project.people.add', undef, '--id', 'ada', '--name', 'Ada', @at );
cli( 'project.people.add', undef, '--id', 'unused', '--name', 'Unused', @at );
( $status, $out ) = cli( 'project.people.update', undef, '--id', 'ada', '--email', 'ada@example.test', @at );
is( decode_json($out)->{email}, 'ada@example.test', 'person update dispatch' );
( $status, $out ) = cli( 'project.people.list', undef, @at );
is( scalar @{ decode_json($out) }, 2, 'person list dispatch' );
cli( 'project.people.deactivate', undef, '--id', 'ada', @at );
cli( 'project.people.activate', undef, '--id', 'ada', @at );

cli( 'project.link-types.add', undef, '--outward', 'implements', '--inward', 'is-implemented-by', @at );
( $status, $out ) = cli( 'project.link-types.list', undef, @at );
ok( scalar @{ decode_json($out) } >= 5, 'link-type list dispatch' );
cli( 'project.link-types.remove', undef, '--outward', 'implements', @at );

( $status, $out ) = cli( 'board.show', undef, '--type', 'ticket', @at );
is( decode_json($out)->{prefix}, 'TKT', 'board show dispatch' );
cli( 'column.add', undef, '--type', 'ticket', '--name', 'doing', '--after', 'backlog', @at );
cli( 'column.add', undef, '--type', 'ticket', '--name', 'review', '--before', 'discard', @at );
cli( 'column.rename', undef, '--type', 'ticket', '--name', 'review', '--new-name', 'verify', @at );
cli( 'column.reorder', undef, '--type', 'ticket', '--name', 'verify', '--before', 'doing', @at );
( $status, $out ) = cli( 'column.list', undef, '--type', 'ticket', @at );
is( decode_json($out)->[1]{name}, 'verify', 'column list/ordering dispatch' );
cli( 'board.refs', undef, '--type', 'sow', '--prefix', 'WORK', '--digits', '4', @at );

my $external = File::Spec->catdir( $root, '.tira', 'epic', 'external' );
make_path($external);
( $status, $out ) = cli( 'column.sync', undef, '--type', 'epic', @at );
is_deeply( decode_json($out)->{unconfigured}, ['external'], 'column sync previews drift' );
cli( 'column.sync', undef, '--type', 'epic', '--apply', @at );
( $status, $out ) = cli( 'project.validate', undef, '--repair-columns', @at );
ok( decode_json($out)->{valid}, 'project repair/validate dispatch' );

my ( $json_fh, $json_file ) = tempfile( DIR => $tmp, SUFFIX => '.json' );
print {$json_fh} '["criterion one","criterion two"]';
close $json_fh;
( $status, $out ) = cli(
    'record.create', 'sow', '--title', 'SOW', '--key-detail', 'Detail', '--deliverable', 'Release',
    '--scope-in', 'API', '--scope-out', 'UI', '--acceptance', 'Accepted', '--test-step', 'Run',
    '--bdd', 'Given', '--atdd', 'Verify', '--assignee', 'ada', '--reporter', 'ada',
    '--label', 'Delivery', '--label', 'delivery', '--due-date', '2026-09-01T17:00:00+01:00',
    '--start-date', '2026-08-06T09:00:00Z', '--sdlc-gate', 'Architecture',
    '--lifecycle', 'Build', '--priority', '4', '--fix-version', '3.0.0',
    '--affects-version', '2.0.0', @at,
);
my $created_sow = decode_json($out);
is( $created_sow->{ref}, 'WORK-0001', 'full record-create field options dispatch' );
is_deeply( $created_sow->{labels}, ['Delivery'], 'CLI record labels are case-insensitively unique' );
is( $created_sow->{priority}, 4, 'CLI record metadata reaches the engine' );
cli( 'record.create', 'epic', '--title', 'Epic', @at );
cli( 'record.create', 'ticket', '--title', 'Ticket', @at );

( $status, $out ) = cli( 'record.show', 'ticket', '--ref', 'TKT-001', @at );
is( decode_json($out)->{title}, 'Ticket', 'record show dispatch' );
( $status, $out ) = cli( 'record.update', 'ticket', '--ref', 'TKT-001', '--set-acceptance', $json_file, @at );
is( scalar @{ decode_json($out)->{acceptance_criteria} }, 2, 'JSON-array replacement dispatch' );
( $status, $out ) = cli(
    'record.update', 'ticket', '--ref', 'TKT-001', '--set-labels', $json_file,
    '--set-affects-versions', $json_file, '--priority', '1', @at,
);
is_deeply( decode_json($out)->{labels}, [ 'criterion one', 'criterion two' ], 'metadata array replacements dispatch' );
( $status, $out ) = cli( 'record.list', 'ticket', '--text', 'Ticket', @at );
is( scalar @{ decode_json($out) }, 1, 'record list dispatch' );

cli( 'hierarchy.link', undef, '--parent', 'WORK-0001', '--child', 'EPC-001', @at );
cli( 'hierarchy.link', undef, '--parent', 'EPC-001', '--child', 'TKT-001', @at );
( $status, $out ) = cli( 'hierarchy.show', undef, '--ref', 'WORK-0001', '--recursive', @at );
is( decode_json($out)->{children}[0]{ref}, 'EPC-001', 'hierarchy show dispatch' );
cli( 'hierarchy.unlink', undef, '--parent', 'EPC-001', '--child', 'TKT-001', @at );

cli( 'record.create', 'ticket', '--title', 'Child', @at );
cli( 'subitem.link', undef, '--parent', 'TKT-001', '--child', 'TKT-002', @at );
cli( 'subitem.unlink', undef, '--parent', 'TKT-001', '--child', 'TKT-002', @at );
cli( 'link.add', undef, '--from', 'TKT-001', '--type', 'relates-to', '--to', 'TKT-002', @at );
( $status, $out ) = cli( 'link.list', undef, '--ref', 'TKT-001', '--type', 'relates-to', @at );
is( scalar @{ decode_json($out) }, 1, 'typed link list dispatch' );
cli( 'link.remove', undef, '--from', 'TKT-001', '--type', 'relates-to', '--to', 'TKT-002', @at );

cli( 'assign.add', undef, '--ref', 'TKT-001', '--person', 'ada', @at );
( $status, $out ) = cli( 'assign.list', undef, '--ref', 'TKT-001', @at );
is_deeply( decode_json($out), ['ada'], 'assignment list dispatch' );
cli( 'assign.remove', undef, '--ref', 'TKT-001', '--person', 'ada', @at );
cli( 'assign.set', undef, '--ref', 'TKT-001', '--person', 'ada', @at );

my ( $text_fh, $text_file ) = tempfile( DIR => $tmp, SUFFIX => '.txt' );
print {$text_fh} 'Comment from file';
close $text_fh;
my ( $bin_fh, $bin_file ) = tempfile( DIR => $tmp, SUFFIX => '.dat' );
binmode $bin_fh;
print {$bin_fh} "matrix\0attachment";
close $bin_fh;
( $status, $out ) = cli( 'comment.add', undef, '--ref', 'TKT-001', '--author', 'ada', '--file', $text_file, '--attach', $bin_file, @at );
is( decode_json($out)->{body}, 'Comment from file', 'comment file/attachment dispatch' );
( $status, $out ) = cli( 'comment.update', undef, '--ref', 'TKT-001', '--comment', 'CMT-001', '--text', 'Updated', @at );
is( decode_json($out)->{body}, 'Updated', 'comment update dispatch' );
( $status, $out ) = cli( 'comment.list', undef, '--ref', 'TKT-001', @at );
is( scalar @{ decode_json($out) }, 1, 'comment list dispatch' );
cli( 'comment.attach', undef, '--ref', 'TKT-001', '--comment', 'CMT-001', '--file', $text_file, @at );

( $status, $out ) = cli( 'attachment.add', undef, '--ref', 'TKT-001', '--file', $bin_file, @at );
my $attachment = decode_json($out);
( $status, $out ) = cli( 'attachment.list', undef, '--ref', 'TKT-001', @at );
ok( @{ decode_json($out) }, 'record attachments list dispatch' );
( $status, $out ) = cli( 'attachment.get', undef, '--sha', $attachment->{sha}, '--extension', 'dat', '--project', $root );
is( $out, "matrix\0attachment", 'attachment get emits raw bytes' );
( $status, $out ) = cli( 'attachment.get', undef, '--sha', $attachment->{sha}, '--extension', 'dat', '--project', $root, '-o', 'path' );
like( $out, qr/\.dat\n\z/, 'attachment path requires explicit selector' );
cli( 'attachment.remove', undef, '--sha', $attachment->{sha}, '--extension', 'dat', @at );
( $status, $out ) = cli( 'attachment.get', undef, '--sha', $attachment->{sha}, '--extension', 'dat', '--project', $root );
is( $status, 1, 'deleted attachment raw retrieval exits one' );
( $status, $out ) = cli( 'attachment.list', undef, '--include-deleted', @at );
ok( grep( { $_->{deleted} } @{ decode_json($out) } ), 'deleted attachment list dispatch' );

( $status, $out ) = cli( 'evidence.add', undef, '--ref', 'TKT-001', '--summary', 'Proof', '--uri', 'https://example.test', '--file', $text_file, '--author', 'ada', @at );
is( decode_json($out)->{summary}, 'Proof', 'evidence add dispatch' );
( $status, $out ) = cli( 'evidence.list', undef, '--ref', 'TKT-001', @at );
is( scalar @{ decode_json($out) }, 1, 'evidence list dispatch' );
cli( 'gate.add', undef, '--ref', 'TKT-001', '--gate', 'QA', '--result', 'pass', '--details', 'OK', '--author', 'ada', @at );
( $status, $out ) = cli( 'gate.list', undef, '--ref', 'TKT-001', @at );
is( scalar @{ decode_json($out) }, 1, 'gate list dispatch' );

cli( 'record.move', 'ticket', '--ref', 'TKT-001', '--column', 'doing', @at );
cli( 'record.discard', 'ticket', '--ref', 'TKT-001', @at );
cli( 'record.restore', 'ticket', '--ref', 'TKT-001', '--column', 'doing', @at );
( $status, $out ) = cli( 'record.clone', 'ticket', '--ref', 'TKT-001', '--title', 'Clone', @at );
like( decode_json($out)->{ref}, qr/^TKT-/, 'record clone dispatch' );

( $status, $out ) = cli( 'search', undef, '--text', 'Ticket', '--type', 'ticket', @at );
ok( @{ decode_json($out) }, 'search dispatch' );
( $status, $out ) = cli( 'dashboard', undef, '--type', 'all', '--include-discard', @at );
ok( exists decode_json($out)->{ticket}{discard}, 'dashboard include-discard dispatch' );
( $status, $out ) = cli( 'dashboard', undef, '--type', 'ticket', '--project', $root, '-o', 'human' );
like( $out, qr/^# Tira Dashboard.*^## TICKET.*^### backlog/ms, 'human dashboard follows explicit column order' );

cli( 'column.remove', undef, '--type', 'ticket', '--name', 'verify', @at );
cli( 'assign.set', undef, '--ref', 'TKT-001', @at );
cli( 'assign.set', undef, '--ref', 'WORK-0001', @at );
cli( 'project.people.remove', undef, '--id', 'unused', @at );

done_testing;

__END__

=head1 NAME

07-command-matrix.t - Comprehensive Tira CLI command matrix

=head1 DESCRIPTION

Runs every DD-389 command family through the shared CLI parser, including
repeatable, replacement, raw-content, path, and repair option combinations.

=cut
