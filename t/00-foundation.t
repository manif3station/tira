#!/usr/bin/env perl

use strict;
use warnings;

BEGIN {
    if (${^TAINT}) {
        $ENV{PATH}   = '/usr/bin:/bin';
        $ENV{TMPDIR} = '/tmp';
        delete @ENV{qw(IFS CDPATH ENV BASH_ENV PERL5LIB PERLLIB PERL_USE_UNSAFE_INC)};
    }
}

use Cwd qw(realpath);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;
use YAML::PP;

use lib 'lib';
use Tira;

my $tmp_value = tempdir( CLEANUP => 1 );
$tmp_value =~ m{\A([^\x00-\x1f\x7f]+)\z} or die "Unsafe temporary path";
my $tmp = $1;
my $project_dir = File::Spec->catdir( $tmp, 'demo' );
my $clock = sub { '2026-08-05T12:34:56+01:00' };
my $tira = Tira->new( clock => $clock );

my $created = $tira->create_project(
    dir  => $project_dir,
    name => 'Demo Project',
);

is( $created->{name}, 'Demo Project', 'project creation returns its name' );
is( $created->{root}, realpath($project_dir), 'project creation returns its canonical root' );
ok( -f File::Spec->catfile( $project_dir, '.tira', 'project.yml' ), 'project.yml is created inside .tira' );

my $yaml = YAML::PP->new( boolean => 'JSON::PP' );
my $project = $yaml->load_file( File::Spec->catfile( $project_dir, '.tira', 'project.yml' ) );
is( $project->{name}, 'Demo Project', 'project.yml records the project name' );
is_deeply( $project->{people}, [], 'project.yml starts with no people' );
ok( ref $project->{link_types} eq 'ARRAY', 'project.yml records configurable link types' );

my %expected_prefix = ( sow => 'SOW', epic => 'EPC', ticket => 'TKT' );
for my $type (qw(sow epic ticket)) {
    my $board = File::Spec->catdir( $project_dir, '.tira', $type );
    ok( -d File::Spec->catdir( $board, 'backlog' ), "$type Backlog folder exists" );
    ok( -d File::Spec->catdir( $board, 'discard' ), "$type Discard folder exists" );
    my $config = $yaml->load_file( File::Spec->catfile( $board, 'config.yml' ) );
    is( $config->{prefix}, $expected_prefix{$type}, "$type prefix is configured" );
    is( $config->{digits}, 3, "$type digit width is configured" );
    is( $config->{next_number}, 1, "$type counter starts at one" );
    is_deeply(
        [ map { $_->{name} } @{ $config->{columns} } ],
        [qw(backlog discard)],
        "$type column order is persisted",
    );
    ok( $_->{protected}, "$type $_->{label} column is protected" ) for @{ $config->{columns} };
}

my $nested = File::Spec->catdir( $project_dir, 'src', 'deeper' );
require File::Path;
File::Path::make_path($nested);
is( $tira->discover_project( start => $nested ), realpath($project_dir), 'project discovery walks upward' );
is( $tira->discover_project( project => $project_dir ), realpath($project_dir), 'explicit project root overrides discovery' );
my $alias_calls = 0;
my $alias_tira = Tira->new( clock => $clock, path_resolver => sub {
    my ($name) = @_;
    $alias_calls++;
    return $project_dir if $name eq 'private-demo';
    return File::Spec->catdir( $tmp, 'secret-missing-target' ) if $name eq 'broken-private';
    die "unknown alias";
} );
is( $alias_tira->discover_project( project => 'private-demo' ), realpath($project_dir),
    'project selector resolves through an injected DD path alias resolver' );
is( $alias_calls, 1, 'alias resolver runs only for a non-path selector' );
is( $alias_tira->discover_project( project => $project_dir ), realpath($project_dir),
    'existing absolute project directory keeps direct-path precedence' );
is( $alias_calls, 1, 'existing project directory bypasses alias resolution' );
eval { $alias_tira->discover_project( project => 'broken-private' ) };
like( $@, qr/Cannot resolve project selector 'broken-private'/, 'invalid alias target reports the selector' );
unlike( $@, qr/secret-missing-target/, 'invalid alias target does not disclose its resolved path' );

my $first = $tira->create_record(
    project     => $project_dir,
    type        => 'ticket',
    title       => 'First ticket',
    description => 'Foundation behavior',
);
my $second = $tira->create_record(
    project => $project_dir,
    type    => 'ticket',
    title   => 'Second ticket',
);

is( $first->{ref}, 'TKT-001', 'first ticket receives the first padded reference' );
is( $second->{ref}, 'TKT-002', 'ticket references increase monotonically' );
is( $first->{linkage}{epic_ref}, undef, 'new ticket is free-ranging' );
is_deeply( $first->{attachments}, [], 'new ticket starts without attachments' );
is_deeply( $first->{comments}, [], 'new ticket starts without comments' );
is_deeply( $first->{subtasks}, [], 'new ticket starts without subtasks' );
is( $first->{created_at}, '2026-08-05T12:34:56+01:00', 'record creation uses an ISO timestamp' );
is( $first->{last_updated}, $first->{created_at}, 'new record last-updated matches creation' );

my $record_path = File::Spec->catfile( $project_dir, '.tira', 'ticket', 'backlog', 'TKT-001.json' );
ok( -f $record_path, 'ticket JSON is stored in the Backlog folder' );
open my $record_fh, '<:raw', $record_path or die "Cannot read $record_path: $!";
my $stored = decode_json( do { local $/; <$record_fh> } );
close $record_fh;
is_deeply( $stored, $first, 'stored JSON is the canonical returned record' );

my $ticket_config = $yaml->load_file( File::Spec->catfile( $project_dir, '.tira', 'ticket', 'config.yml' ) );
is( $ticket_config->{next_number}, 3, 'counter persists the next unused number' );

my $toon = $tira->format_output( { records => [ $first, $second ] } );
like( $toon, qr/records\[2\]/, 'TOON is the default output format' );
my $json = $tira->format_output( $first, output => 'json' );
unlike( $json, qr/\n./s, 'JSON output is compact by default (CA14)' );
like( $json, qr/"ref":"TKT-001"/, 'compact JSON contains the record reference' );
my $human = $tira->format_output( $first, output => 'human' );
like( $human, qr/^# TKT-001: First ticket$/m, 'human output is Markdown' );

eval { $tira->create_record( project => $project_dir, type => 'ticket' ) };
like( $@, qr/title is required/, 'record creation requires a title' );
eval { $tira->create_record( project => $project_dir, type => 'unknown', title => 'No' ) };
like( $@, qr/Unsupported record type/, 'record creation rejects unknown types' );
eval { $tira->discover_project( start => $tmp ) };
like( $@, qr/No Tira project found/, 'project discovery reports a missing project' );

done_testing;

__END__

=head1 NAME

00-foundation.t - Acceptance tests for the governed Tira foundation

=head1 DESCRIPTION

Proves project creation and discovery, board configuration, record allocation,
filesystem persistence, and output formatting for.

=cut
