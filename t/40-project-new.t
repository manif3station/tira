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
my $tira = Tira->new( clock => sub { '2026-08-07T15:00:00Z' } );

sub run_cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => 'project.new', argv => \@argv );
    return ( $status, $out, $err );
}

my $columns = 'Backlog, Planning, Documenting, Ready, In Progress, '
  . 'Vulnerability Scanner, Unit Testing, E2E Testing, Done / Release';

my $root = File::Spec->catdir( $tmp, 'mt5' );
my $summary = $tira->project_new(
    name => 'MT5', dir => $root,
    members => [ 'K-Bot', 'Michael' ],
    columns => [$columns],
    sow_prefix => 'M5S', epic_prefix => 'M5E', ticket_prefix => 'M5T',
);

is( $summary->{project}{name}, 'MT5', 'the project is created with its name' );
is_deeply( [ map { $_->{id} } @{ $summary->{people} } ], [ 'K-Bot', 'Michael' ],
    'every member is added in order' );
is_deeply( [ map { $_->{prefix} } @{ $summary->{boards} } ], [ 'M5S', 'M5E', 'M5T' ],
    'each board gets its own reference prefix' );

for my $type (qw(sow epic ticket)) {
    my $board = $tira->column_list( project => $root, type => $type );
    is_deeply(
        [ map { $_->{name} } @{$board} ],
        [ qw(backlog planning documenting ready in-progress
             vulnerability-scanner unit-testing e2e-testing done-release discard) ],
        "$type columns are slugified and ordered as given, Discard last"
    );
    my %label = map { $_->{name} => $_->{label} } @{$board};
    is( $label{'done-release'}, 'Done / Release', "$type keeps the human label verbatim" );
    is( $label{'in-progress'}, 'In Progress', "$type keeps multi-word labels" );
    is( $label{backlog}, 'Backlog', "$type leaves the protected Backlog column untouched" );
}

my $first = $tira->create_record( project => $root, type => 'sow', title => 'First statement' );
is( $first->{ref}, 'M5S-001',
    'prefixes are set before anything can create a record, so the first reference is 001' );
is( $tira->create_record( project => $root, type => 'epic', title => 'First epic' )->{ref},
    'M5E-001', 'the epic board carries its own prefix' );
is( $tira->create_record( project => $root, type => 'ticket', title => 'First ticket' )->{ref},
    'M5T-001', 'the ticket board carries its own prefix' );

# Re-running must be safe: existing columns and people are left alone.
my $again = $tira->project_new(
    name => 'MT5', dir => $root, members => ['K-Bot'], columns => [$columns],
);
is( scalar @{ $tira->column_list( project => $root, type => 'sow' ) }, 10,
    're-running adds no duplicate columns' );
is( scalar @{ $tira->person_list( project => $root ) }, 2, 're-running adds no duplicate people' );
my %skipped_kind;
$skipped_kind{ $_->{kind} }++ for @{ $again->{skipped} };
is( $skipped_kind{project}, 1, 'the summary reports the project already existed' );
is( $skipped_kind{person}, 1, 'the summary reports the member already existed' );
is( $skipped_kind{column}, 27,
    'the summary reports every column already present — nine on each of three boards' );

# Nothing at all is written when any input is invalid.
my $rejected = File::Spec->catdir( $tmp, 'rejected' );
for my $case (
    [ { name => 'Bad', dir => $rejected, columns => ['///'] }, qr/Column name/, 'an unslugifiable column' ],
    [ { name => 'Bad', dir => $rejected, sow_prefix => 'lower' }, qr/prefix/i, 'a lowercase prefix' ],
    [ { name => 'Bad', dir => $rejected, digits => 0 }, qr/digits/i, 'a zero digit count' ],
    [ { name => 'Bad', dir => $rejected, members => [''] }, qr/member/i, 'an empty member' ],
    [ { dir => $rejected }, qr/name/i, 'a missing project name' ],
) {
    my ( $args, $error, $label ) = @{$case};
    eval { $tira->project_new( %{$args} ) };
    like( $@, $error, "$label is refused" );
    ok( !-e $rejected, "$label leaves no project behind" );
}

# Adversarial review found these; each one could brick a project permanently.
my $guarded = File::Spec->catdir( $tmp, 'guarded' );
eval { $tira->project_new( name => 'Clash', dir => $guarded, sow_prefix => 'TKT' ) };
like( $@, qr/shared by the .* and ticket boards/,
    'a prefix colliding with another board default is refused' );
ok( !-e $guarded, 'the refused collision wrote nothing' );
eval {
    $tira->project_new(
        name => 'Clash', dir => $guarded,
        sow_prefix => 'ZZ', epic_prefix => 'ZZ', ticket_prefix => 'ZZ',
    );
};
like( $@, qr/shared by/, 'prefixes colliding with each other are refused' );
eval { $tira->project_new( name => 'Long', dir => $guarded, columns => [ 'x' x 300 ] ) };
like( $@, qr/too long/, 'a column name longer than the filesystem allows is refused up front' );
ok( !-e $guarded, 'the over-long column wrote nothing' );
eval { $tira->project_new( name => 'Empty', dir => $guarded, sow_prefix => '' ) };
like( $@, qr/Invalid sow prefix/, 'an explicitly empty prefix is refused, not silently ignored' );

eval { $tira->project_new( name => 'Not MT5', dir => $root ) };
like( $@, qr/A different project \('MT5'\) already exists there/,
    'an existing project with a different name is never adopted' );
is( $tira->project_show( project => $root )->{name}, 'MT5',
    'the foreign-name refusal leaves the existing project untouched' );
eval { $tira->project_new( name => 'MT5', dir => $root, sow_prefix => 'XYZ' ) };
like( $@, qr/already has records, so its prefix cannot change/,
    'a prefix change is refused once the board holds records, because counters never rewind' );
is( $tira->board_refs( project => $root, type => 'sow' )->{prefix}, 'M5S',
    'the refused prefix change left the board alone' );

my ( $status, $out, $err ) = run_cli(
    '--name', 'CLI made', '--dir', File::Spec->catdir( $tmp, 'cli' ),
    '--members', 'K-Bot, Michael',
    '--columns', $columns,
    '--sow-prefix', 'C1S', '--epic-prefix', 'C1E', '--ticket-prefix', 'C1T',
    '-o', 'json',
);
is( $status, 0, 'the CLI bootstrap succeeds' );
my $payload = decode_json($out);
is( $payload->{project}{name}, 'CLI made', 'the CLI returns a structured summary' );
is( scalar @{ $payload->{people} }, 2, 'comma-separated members are split' );
is_deeply( [ map { $_->{prefix} } @{ $payload->{boards} } ], [ 'C1S', 'C1E', 'C1T' ],
    'the CLI sets every prefix' );
is( scalar @{ $payload->{boards}[0]{columns} }, 10, 'the CLI builds the whole column set' );

( $status, $out, $err ) = run_cli(
    '--name', 'Nope', '--dir', File::Spec->catdir( $tmp, 'nope' ),
    '--sow-prefix', 'bad', '-o', 'json',
);
is( $status, 2, 'an invalid CLI prefix exits 2' );
ok( !-e File::Spec->catdir( $tmp, 'nope' ), 'the rejected CLI run wrote nothing' );

( $status, $out, $err ) = run_cli( '--dir', File::Spec->catdir( $tmp, 'unnamed' ), '-o', 'json' );
is( $status, 2, 'a missing name exits 2' );

( $status, $out, $err ) = run_cli( '--help' );
is( $status, 0, 'the command offers help' );
unlike( $out, qr/--project|TIRA_HOME/, 'help never discloses project selection' );

my ( $scope_status, undef, $scope_err ) = do {
    my ( $o, $e ) = ( '', '' );
    open my $so, '>', \$o or die $!;
    open my $se, '>', \$e or die $!;
    local *STDOUT = $so;
    local *STDERR = $se;
    my $s = Tira::CLI->run(
        command => 'project.show',
        argv => [ '--project', $root, '--columns', 'Backlog', '-o', 'json' ],
    );
    ( $s, $o, $e );
};
is( $scope_status, 2, 'the bootstrap options are refused on other commands' );
like( $scope_err, qr/project\.new/, 'the refusal names the command they belong to' );

done_testing;

__END__

=head1 NAME

40-project-new.t - DD-446 one-command project bootstrap

=head1 DESCRIPTION

Proves C<tira.project.new>: a single call creates the project, its
members, per-board reference prefixes, and a shared column set given as
human text and slugified automatically with labels preserved. Protected
default columns are skipped so the natural list works verbatim and the
command is safe to re-run. Every input is validated before the first
write, so a rejected invocation leaves no project behind, and prefixes
are applied before any record can exist so the first reference is 001.

=cut
