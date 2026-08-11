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
my $root = File::Spec->catdir( $tmp, 'projection' );
my $tira = Tira->new( clock => sub { '2026-08-07T00:00:00Z' } );
$tira->create_project( name => 'Projection', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
my $ticket = $tira->create_record(
    project => $root, type => 'ticket', title => 'Projected',
    description => 'A long body that projection should be able to drop', assignee => 'ada',
);
$tira->comment_add( project => $root, ref => $ticket->{ref}, author => 'ada', text => 'noise' );
$tira->create_record( project => $root, type => 'epic', title => 'Epic member' );
$tira->create_record( project => $root, type => 'sow', title => 'SOW member' );

my $projected = $tira->record_show( project => $root, ref => $ticket->{ref}, fields => ['column'] );
is_deeply( [ sort keys %{$projected} ], [qw(column ref)], 'field selection returns ref plus the named field' );
is( $projected->{column}, 'backlog', 'the selected value is the stored one' );

$projected = $tira->record_show(
    project => $root, ref => $ticket->{ref}, fields => [ 'column,sdlc_gate', 'assignee' ],
);
is_deeply( [ sort keys %{$projected} ], [qw(assignee column ref sdlc_gate)],
    'comma-separated and repeated selections accumulate' );
ok( exists $projected->{sdlc_gate} && !defined $projected->{sdlc_gate},
    'a selected null field stays visible as null' );

eval { $tira->record_show( project => $root, ref => $ticket->{ref}, fields => ['nosuchfield'] ) };
like( $@, qr/Unknown field 'nosuchfield'/, 'an unknown selection fails loudly naming the field' );

eval { $tira->record_show( project => $root, ref => $ticket->{ref}, fields => ['column,'] ) };
like( $@, qr/Empty field name/, 'an empty field name is refused, never silently dropped' );

my $trimmed = $tira->record_show(
    project => $root, ref => $ticket->{ref}, exclude_fields => ['description,comments'],
);
ok( !exists $trimmed->{description}, 'an excluded field is omitted' );
ok( !exists $trimmed->{comments}, 'every named exclusion applies' );
is( $trimmed->{title}, 'Projected', 'unnamed fields survive exclusion' );
is( $trimmed->{column}, 'backlog', 'the computed column survives exclusion' );

eval { $tira->record_show( project => $root, ref => $ticket->{ref}, exclude_fields => ['nosuchfield'] ) };
like( $@, qr/Unknown field 'nosuchfield'/, 'unknown exclusions fail like unknown selections' );

my $contradiction = $tira->record_show(
    project => $root, ref => $ticket->{ref},
    fields => ['description'], exclude_fields => ['description'],
);
is_deeply( [ keys %{$contradiction} ], ['ref'],
    'exclusion applies after selection, leaving only the ref' );

my $listed = $tira->record_list( project => $root, type => 'ticket', fields => ['column'] );
is_deeply( [ sort keys %{ $listed->[0] } ], [qw(column ref)], 'list projects every record' );

my $exported = $tira->export_records( project => $root, fields => ['column'] );
is( $exported->{count}, 3, 'export count is unaffected by projection' );
my %shapes = map { join( ',', sort keys %{$_} ) => 1 } @{ $exported->{records} };
is_deeply( [ keys %shapes ], ['column,ref'], 'export projects sow, epic, and ticket uniformly' );

my $unprojected = $tira->record_show( project => $root, ref => $ticket->{ref} );
ok( exists $unprojected->{description} && exists $unprojected->{comments},
    'reads without selection keep the full record' );

sub run_cli {
    my ( $command, $type, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run(
        command => $command, ( defined $type ? ( type => $type ) : () ), argv => \@argv,
    );
    return ( $status, $out, $err );
}

my ( $status, $out, $err ) = run_cli(
    'record.show', 'ticket',
    '--project', $root, '--ref', $ticket->{ref}, '--fields', 'column', '-o', 'json',
);
is( $status, 0, 'CLI field selection succeeds' );
my $payload = decode_json($out);
is_deeply( [ sort keys %{$payload} ], [qw(column ref)], 'CLI show returns only ref and the field' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket',
    '--project', $root, '--ref', $ticket->{ref},
    '--fields', 'column,sdlc_gate', '--fields', 'assignee', '-o', 'json',
);
is( $status, 0, 'repeated --fields flags succeed' );
is_deeply( [ sort keys %{ decode_json($out) } ], [qw(assignee column ref sdlc_gate)],
    'repeated CLI flags accumulate with comma lists' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket',
    '--project', $root, '--ref', $ticket->{ref}, '--fields', 'nosuchfield', '-o', 'json',
);
is( $status, 2, 'an unknown CLI field exits 2' );
like( $err, qr/nosuchfield/, 'the CLI error names the offending field' );

( $status, $out, $err ) = run_cli(
    'export', undef,
    '--project', $root, '--exclude-fields', 'description,comments', '-o', 'json',
);
is( $status, 0, 'CLI export exclusion succeeds' );
$payload = decode_json($out);
is( $payload->{count}, 3, 'export envelope keeps its count' );
ok( !exists $payload->{records}[0]{description} && !exists $payload->{records}[0]{comments},
    'excluded fields are gone from every exported record' );
ok( exists $payload->{records}[0]{title}, 'export exclusion keeps the rest' );

( $status, $out, $err ) = run_cli(
    'record.update', 'ticket',
    '--project', $root, '--ref', $ticket->{ref}, '--title', 'Nope', '--fields', 'column', '-o', 'json',
);
is( $status, 2, 'field selection on a mutation exits 2 instead of being ignored' );
like( $err, qr/show, list, and export/, 'the error explains where selection applies' );

done_testing;

__END__

=head1 NAME

25-field-selection.t - field selection and exclusion (CA01-CA03)

=head1 DESCRIPTION

Proves C<fields>/C<exclude_fields> projection on show, list, and export:
ref always kept on selection, exclusion applied after selection, unknown
and empty field names fail loudly, count preserved on export, and the
CLI flags C<--fields>/C<--exclude-fields> accumulate and exit 2 on
misuse.

=cut
