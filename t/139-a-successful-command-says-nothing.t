#!/usr/bin/env perl
# A command that worked writes nothing to the error stream.
#
# tira.backup.import checks the bundle before touching anything, and git prints
# "<file> is okay" on the error stream when that check succeeds. A successful
# command that writes to stderr reads like a warning to whoever is watching, and
# --quiet does not silence it - git says it anyway.
#
# Two ways were tried and both cost more than the line is worth.
#
# Reopening this process's error stream and putting it back looked equivalent to
# silencing the child and was not: every caller that had redirected it - each
# test that captures it, and the served dashboard - got the real one back. Four
# assertions about refusal messages went silent while the refusals themselves
# kept working, which is the exact shape of a change that looks harmless.
#
# Forking a child that silences itself is correct and unmeasurable: the child
# execs away before any coverage counter is written, so those lines can never be
# covered and the gate would have to be told to ignore them. A gate with an
# exception in it is a gate somebody will widen.
#
# The third way is the one that costs nothing. The parent hands the child a
# filehandle for its error stream, so no Perl runs in the child and nothing in
# this process is reopened. Both halves are tested here, because the first
# attempt passed the half everybody thinks of.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

plan skip_all => 'git is not installed here' if !Tira::CLI::_program_exists('git');

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T21:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Quiet', dir => $root, members => ['michael'],
    columns => ['backlog, done'],
    sow_prefix => 'QTS', epic_prefix => 'QTE', ticket_prefix => 'QTT',
);
$tira->create_record( project => $root, type => 'ticket', title => 'Something to carry' );

sub run {
    my ( $project, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run( command => shift(@argv), tira => $tira,
            argv => [ '--project', $project, @argv ] );
    };
    return ( $status, $out, $err );
}

my $bundle = File::Spec->catfile( $tmp, 'board.bundle' );
is( ( run( $root, 'backup' ) )[0], 0, 'the board is backed up' );
is( ( run( $root, 'backup.export', '--file', $bundle ) )[0], 0, 'and exported' );

# --- the import says nothing at all ---------------------------------------------
#
# Captured from a real child process, not by localising STDOUT and STDERR. A
# Perl-level redirection does not touch the error stream the git child inherits,
# so asserting on it here passed while the noise went to the terminal anyway -
# the test passing for the wrong reason, which is the fault this project keeps
# finding in its own checks.

my $elsewhere = File::Spec->catdir( $tmp, 'elsewhere' );
my $entrypoint = File::Spec->catfile(qw(skills backup cli import));
my $noise = File::Spec->catfile( $tmp, 'stderr' );

my $status = do {
    local $ENV{PERL5OPT}              = '';
    local $ENV{HARNESS_PERL_SWITCHES} = '';
    open my $saved, '>&', \*STDERR or die $!;
    open STDERR, '>', $noise or die $!;
    my $ran = system $^X, '-Ilib', $entrypoint,
      '--project', $elsewhere, '--file', $bundle;
    open STDERR, '>&', $saved or die $!;
    close $saved;
    $ran;
};
is( $status, 0, 'a bundle imports' );

my $said = do { open my $fh, '<', $noise or die $!; local $/; <$fh> };
is( $said, '', 'and writes nothing to the error stream a person is watching' );

ok( -d File::Spec->catdir( $elsewhere, '.tira' ), 'and the board really arrived' );

# --- and the error stream still belongs to whoever redirected it -----------------
#
# The half the first attempt broke. Silencing the check by reopening this
# process's error stream took it away from every later caller, and the behaviour
# underneath kept working - so nothing failed except the assertions that were
# watching.

my ( $refused, undef, $refusal ) = run( $root, 'backup.import', '--file', $bundle );
isnt( $refused, 0, 'importing over a board is still refused without agreement' );
like( $refusal, qr/--yes/, 'and the refusal is still captured by whoever redirected the stream' );

my ( undef, undef, $after ) = run( $elsewhere, 'backup.restore' );
like( $after, qr/discard|--yes/i,
    'and a later command in the same process still has its error stream' );

# --- a bundle that is not one still fails loudly ---------------------------------
#
# Silence on success must not become silence on failure. The check is what stops
# a bad file being unpacked over a board.

my $rubbish = File::Spec->catfile( $tmp, 'not-a-bundle' );
open my $fh, '>', $rubbish or die $!;
print {$fh} "this is not a bundle\n";
close $fh;
my ( $rejected, undef, $why ) = run( File::Spec->catdir( $tmp, 'nowhere' ),
    'backup.import', '--file', $rubbish );
isnt( $rejected, 0, 'a file that is not a bundle is refused' );
like( $why, qr/not a bundle/i, 'and says so' );
ok( !-d File::Spec->catdir( $tmp, 'nowhere', '.tira' ),
    'with nothing written, so a refusal never half-restores' );

# --- and the quiet runner itself ------------------------------------------------
#
# The thing every assertion above stands on. It answers with the exit status and
# swallows the opinion, so all three outcomes are asked of it directly rather
# than inferred from a command that happens to use it.

ok( Tira::CLI::_running_quietly( 'git', '--version' ),
    'a command that works answers true' );
ok( !Tira::CLI::_running_quietly( 'git', 'bundle', 'verify', $rubbish ),
    'a command that fails answers false, whatever it printed' );
ok( !Tira::CLI::_running_quietly('tira-no-such-program-anywhere'),
    'and a program that is not installed answers false rather than dying' );

done_testing;

__END__

=head1 NAME

139-a-successful-command-says-nothing.t - a command that worked writes nothing to stderr

=head1 DESCRIPTION

C<git bundle verify> prints on the error stream when it succeeds, so a
successful import looked like it had warned about something. Silencing it by
reopening this process's error stream took that stream away from every caller
that had redirected it; silencing it in a forked child put lines in the codebase
that no coverage tool can measure.

The parent now hands the child a filehandle for its error stream. Nothing here
is reopened and no Perl runs in the child. Both halves are asserted - the import
is silent, and a later command in the same process still has its error stream -
because the first attempt passed the half everybody thinks of.

=cut
