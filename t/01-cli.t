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

use File::Spec;
use File::Temp qw(tempdir);
use IPC::Open3;
use Cpanel::JSON::XS qw(decode_json);
use Symbol qw(gensym);
use Test::More;

sub run_command {
    my (@command) = @_;
    my $error = gensym;
    my $pid = open3( my $input, my $output, $error, @command );
    close $input;
    my $stdout = do { local $/; <$output> } // '';
    my $stderr = do { local $/; <$error> } // '';
    waitpid $pid, 0;
    return ( $? >> 8, $stdout, $stderr );
}

my $tmp_value = tempdir( CLEANUP => 1 );
$tmp_value =~ m{\A([^\x00-\x1f\x7f]+)\z} or die "Unsafe temporary path";
my $tmp = $1;
my $project = File::Spec->catdir( $tmp, 'cli-project' );
$^X =~ /\A([^\x00-\x1f\x7f]+)\z/ or die "Unsafe Perl interpreter path";
my @perl = ($1);
push @perl, '-I/root/perl5/lib/perl5' if ${^TAINT};

my ( $status, $stdout, $stderr ) = run_command(
    @perl, 'skills/project/cli/create',
    '--name', 'CLI Project', '--dir', $project,
);
is( $status, 0, 'project create exits successfully' );

# From here the board is named the one way there is: in the environment, which
# every command reads and which subprocesses inherit. Creating a board is the
# exception and is not a selector - --dir above is where the board is about to
# be, not which board to work on. TKT-250.
$ENV{TIRA_HOME} = $project;
is( $stderr, '', 'project create has no stderr output' );
like( $stdout, qr/name:\s+"?CLI Project"?/, 'project create defaults to TOON' );
ok( -f File::Spec->catfile( $project, '.tira', 'project.yml' ), 'CLI creates the canonical project layout' );

( $status, $stdout, $stderr ) = run_command(
    @perl, 'skills/sow/cli/create', '--title', 'CLI SOW', '-o', 'json',
);
is( $status, 0, 'SOW create exits successfully' );
my $sow = decode_json($stdout);
is( $sow->{ref}, 'SOW-001', 'SOW CLI allocates the configured reference' );
is_deeply( $sow->{linkage}{epic_refs}, [], 'SOW linkage is initially empty' );

( $status, $stdout, $stderr ) = run_command(
    @perl, 'skills/epic/cli/create', '--title', 'CLI Epic', '-o', 'human',
);
is( $status, 0, 'epic create exits successfully' );
like( $stdout, qr/^# EPC-001: CLI Epic$/m, 'epic human output is Markdown' );

( $status, $stdout, $stderr ) = run_command(
    @perl, 'skills/ticket/cli/create', '--title', 'CLI Ticket', '--description', 'From the CLI', '-o', 'toon',
);
is( $status, 0, 'ticket create exits successfully' );
like( $stdout, qr/ref:\s+"?TKT-001"?/, 'ticket explicit TOON output includes its reference' );

{
    local $ENV{TIRA_HOME} = $project;
    ( $status, $stdout, $stderr ) = run_command(
        @perl, 'skills/ticket/cli/create', '--title', 'Environment ticket', '-o', 'json',
    );
}
is( $status, 0, 'TIRA_HOME selects the project without --project' );
is( decode_json($stdout)->{ref}, 'TKT-002', 'environment-selected project advances its ticket sequence' );

( $status, $stdout, $stderr ) = run_command( @perl, 'skills/ticket/cli/create');
isnt( $status, 0, 'invalid CLI request exits nonzero' );
is( $stdout, '', 'invalid CLI request does not write success output' );
like( $stderr, qr/error:\s+"?Record title is required/, 'CLI errors use the default TOON format' );

( $status, $stdout, $stderr ) = run_command( @perl, 'cli/skills' );
is( $status, 0, 'skills documentation command exits successfully' );
is( $stderr, '', 'skills documentation command has no stderr output' );
SKIP: {
    # Read back through a pipe on the Windows lab this does not match, although
    # running the same command there by hand prints exactly this line. It is the
    # third face of one problem on that platform - child processes and their
    # output under a harness - and TKT-035 owns it.
    skip 'output read back through a pipe does not match on this platform', 1
      if $^O eq 'MSWin32';
    like( $stdout, qr/^# Tira Agent Skill Manual$/m, 'skills command prints raw SKILLS.md' );
}

done_testing;

__END__

=head1 NAME

01-cli.t - Acceptance tests for Tira Developer Dashboard commands

=head1 DESCRIPTION

Executes the nested project, SOW, epic, and ticket command files and verifies
the TOON-first output contract, explicit JSON and Markdown output, error
handling, and raw agent-manual command.

=cut
