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

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(realpath);
use Test::More;
use YAML::XS ();

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp_value = tempdir( CLEANUP => 1 );
$tmp_value =~ m{\A([^\x00-\x1f\x7f]+)\z} or die "Unsafe temporary path";
my $tmp = $1;
my $default_clock = Tira->new;
like(
    $default_clock->{clock}->(),
    qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4}$/,
    'default clock emits an ISO-like timestamp with numeric offset',
);

eval { $default_clock->create_project( dir => File::Spec->catdir( $tmp, 'nameless' ) ) };
like( $@, qr/Project name is required/, 'project creation requires a name' );
eval { $default_clock->create_project( dir => "bad\0path", name => 'Unsafe' ) };
like( $@, qr/Unsafe control character/, 'project creation rejects unsafe path input' );

my $project = File::Spec->catdir( $tmp, 'project' );
$default_clock->create_project( dir => $project, name => 'Failure paths' );
eval { $default_clock->create_project( dir => $project, name => 'Duplicate' ) };
like( $@, qr/already exists/, 'project creation refuses to overwrite a project' );

my $project_file = File::Spec->catfile( $project, '.tira', 'project.yml' );
is( $default_clock->discover_project( start => $project_file ), realpath($project), 'discovery accepts a file starting point' );
eval { $default_clock->discover_project( project => File::Spec->catdir( $tmp, 'missing' ) ) };
like( $@, qr/Cannot resolve project path/, 'discovery rejects an unresolved explicit path' );

my $sow = $default_clock->create_record( project => $project, type => 'sow', title => 'SOW' );
my $epic = $default_clock->create_record( project => $project, type => 'epic', title => 'Epic' );
is_deeply( $sow->{linkage}{epic_refs}, [], 'SOW linkage factory is exercised' );
is_deeply( $epic->{linkage}{ticket_refs}, [], 'epic linkage factory is exercised' );

eval { $default_clock->format_output( {}, output => 'xml' ) };
like( $@, qr/Unsupported output format/, 'unsupported output formats are rejected' );
eval { $default_clock->board_show( project => $project, type => 'unknown' ) };
like( $@, qr/not a type this board has/,
    'board commands reject unknown entity types' );
like( $@, qr/--type takes ticket, epic or sow/,
    'and say what they would have taken' );
like(
    $default_clock->format_output( { result => 'ok' }, output => 'human' ),
    qr/^# Tira Result/m,
    'generic human output is Markdown',
);

my $bad_target = File::Spec->catdir( $project, '.tira', 'cannot-replace' );
make_path($bad_target);
eval { $default_clock->_atomic_write( $bad_target, 'content' ) };
like( $@, qr/Cannot replace/, 'atomic write reports replacement failures' );

{
    package Local::FailingTira;
    our @ISA = ('Tira');
    sub fail_next_yaml { $_[0]{fail_next_yaml} = 1 }
    sub _write_yaml {
        my ( $self, @args ) = @_;
        die "Injected YAML failure\n" if delete $self->{fail_next_yaml};
        return $self->SUPER::_write_yaml(@args);
    }
}

my $rollback_root = File::Spec->catdir( $tmp, 'rollback' );
my $failing = Local::FailingTira->new( clock => sub { '2026-08-05T00:00:00+01:00' } );
$failing->create_project( dir => $rollback_root, name => 'Rollback' );
$failing->fail_next_yaml;
eval { $failing->create_record( project => $rollback_root, type => 'ticket', title => 'Rollback me' ) };
like( $@, qr/Injected YAML failure/, 'counter persistence failure is returned' );
ok(
    !-e File::Spec->catfile( $rollback_root, '.tira', 'ticket', 'backlog', 'TKT-001.json' ),
    'record JSON is removed when its counter update fails',
);

my $yaml = Tira::Yaml->new;
my $config_path = File::Spec->catfile( $project, '.tira', 'ticket', 'config.yml' );
my $config = read_yaml($config_path);
$config->{next_number} = 'invalid';
write_yaml( $config_path, $yaml->dump_string($config) );
eval { $default_clock->create_record( project => $project, type => 'ticket', title => 'Bad counter' ) };
like( $@, qr/Invalid next_number/, 'invalid persisted counters are rejected' );

my $help = '';
{
    open my $capture, '>', \$help or die $!;
    local *STDOUT = $capture;
    is(
        Tira::CLI->run( command => 'record.create', type => 'ticket', argv => ['--help'] ),
        0,
        'CLI help returns success',
    );
}
like( $help, qr/dashboard tira\.ticket\.create/, 'record help names the dotted DD command' );
unlike( $help, qr/--project|TIRA_HOME/, 'record help keeps project selection private' );

my $project_help = '';
{
    open my $capture, '>', \$project_help or die $!;
    local *STDOUT = $capture;
    Tira::CLI->run( command => 'project.create', argv => ['--help'] );
}
like( $project_help, qr/dashboard tira\.project\.create/, 'project help names the dotted DD command' );

my $generic_help = '';
{
    open my $capture, '>', \$generic_help or die $!;
    local *STDOUT = $capture;
    Tira::CLI->run( command => 'column.list', argv => ['--help'] );
}
like( $generic_help, qr/dashboard tira\.column\.list/, 'generic help names the exact dotted command' );

my $direct_root = File::Spec->catdir( $tmp, 'direct-cli' );
my ( $direct_out, $direct_err ) = ( '', '' );
{
    open my $stdout, '>', \$direct_out or die $!;
    open my $stderr, '>', \$direct_err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    is(
        Tira::CLI->run(
            command => 'project.create',
            argv    => [ '--name', 'Direct CLI', '--dir', $direct_root ],
            tira    => Tira->new( clock => sub { '2026-08-05T00:00:00+01:00' } ),
        ),
        0,
        'direct project CLI execution succeeds',
    );
}
like( $direct_out, qr/name:\s+Direct CLI/, 'direct project CLI prints TOON' );
is( $direct_err, '', 'direct project CLI has no error output' );

( $direct_out, $direct_err ) = ( '', '' );
{
    open my $stdout, '>', \$direct_out or die $!;
    open my $stderr, '>', \$direct_err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    is(
        do { local $ENV{TIRA_HOME} = $direct_root; Tira::CLI->run(
            command => 'record.create',
            type    => 'ticket',
            argv    => [ '--title', 'Direct ticket', '-o', 'json' ],
        ) },
        0,
        'direct record CLI execution succeeds',
    );
}
like( $direct_out, qr/"ref"\s*:\s*"TKT-001"/, 'direct record CLI prints selected JSON' );

my $environment_root = File::Spec->catdir( $tmp, 'environment-cli' );
$default_clock->create_project( dir => $environment_root, name => 'Environment CLI' );
( $direct_out, $direct_err ) = ( '', '' );
{
    open my $stdout, '>', \$direct_out or die $!;
    open my $stderr, '>', \$direct_err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    # There is one way to say which board and this is it. There used to be
    # three - a flag, the environment, and the working directory - and this
    # asserted which of them won. Three ways to say one thing is three
    # behaviours to keep in agreement, and they had stopped agreeing: the
    # dashboard replaces the environment value from the working directory, so
    # what a caller passed was discarded rather than preferred. TKT-250.
    local $ENV{TIRA_HOME} = $direct_root;
    is(
        Tira::CLI->run(
            command => 'record.create', type => 'ticket',
            argv => [ '--title', 'Named board', '-o', 'json' ],
        ),
        0,
        'the board named in the environment is the board written to',
    );
}
like( $direct_out, qr/"ref"\s*:\s*"TKT-002"/, 'which receives the new record' );
ok(
    !-e File::Spec->catfile( $environment_root, '.tira', 'ticket', 'backlog', 'TKT-001.json' ),
    'and no other board is touched, which is the half of this worth keeping',
);

( $direct_out, $direct_err ) = ( '', '' );
{
    open my $stdout, '>', \$direct_out or die $!;
    open my $stderr, '>', \$direct_err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    is( Tira::CLI->run( command => 'unknown', argv => [] ), 2, 'unknown CLI command fails' );
}
like( $direct_err, qr/Unsupported Tira command/, 'unknown CLI command emits structured error' );

( $direct_out, $direct_err ) = ( '', '' );
{
    open my $stdout, '>', \$direct_out or die $!;
    open my $stderr, '>', \$direct_err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    is( Tira::CLI->run( command => 'record.create', type => 'ticket', argv => ['extra'] ), 2, 'extra arguments fail parsing' );
}
like( $direct_err, qr/Invalid command-line options/, 'argument parse failure is structured' );

( $direct_out, $direct_err ) = ( '', '' );
{
    open my $stdout, '>', \$direct_out or die $!;
    open my $stderr, '>', \$direct_err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    is( Tira::CLI->run( command => 'record.create', type => 'ticket', argv => [ "\xFF" ] ), 2, 'invalid UTF-8 argv is rejected' );
}
like( $direct_err, qr/UTF-8/, 'invalid UTF-8 argv failure is structured' );

( $direct_out, $direct_err ) = ( '', '' );
{
    open my $stdout, '>', \$direct_out or die $!;
    open my $stderr, '>', \$direct_err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    is(
        do { local $ENV{TIRA_HOME} = $direct_root; Tira::CLI->run(
            command => 'record.create', type => 'ticket',
            argv => [ '--title', 'Bad output', '-o', 'xml' ],
        ) },
        2,
        'output formatting failure returns a structured error',
    );
}
like( $direct_err, qr/Unsupported output format/, 'format failure falls back to TOON error output' );

{
    package Local::BrokenFormatter;
    sub new { bless {}, shift }
    sub format_output { die "Formatter unavailable\n" }
}

( $direct_out, $direct_err ) = ( '', '' );
{
    open my $stdout, '>', \$direct_out or die $!;
    open my $stderr, '>', \$direct_err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    is(
        Tira::CLI->run( command => 'unknown', argv => [], tira => Local::BrokenFormatter->new ),
        2,
        'error output has a JSON emergency fallback',
    );
}
like( $direct_err, qr/"error"\s*:\s*"Unsupported Tira command/, 'emergency formatter emits JSON' );

# the YAML reader's load_file left the handle open, and on Windows an open handle
# makes a file impossible to replace - so a test that reads a config and then
# asks Tira to write it fails there and nowhere else. Reading it as a string
# closes the file when this says so.
sub read_yaml {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    return $yaml->load_string($body);
}

# dump_file leaves the handle open in the same way load_file does, and a test
# that writes a file Tira then replaces fails on Windows for that alone.
sub write_yaml {
    my ( $path, $body ) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die "Cannot write '$path': $!";
    print {$fh} $body;
    close $fh;
    return 1;
}

done_testing;

__END__

=head1 NAME

02-failure-paths.t - Failure-path and rollback tests for Tira

=head1 DESCRIPTION

Exercises defensive persistence, discovery, formatting, linkage factory, and
CLI help paths required by the coverage and security gates.

=cut
