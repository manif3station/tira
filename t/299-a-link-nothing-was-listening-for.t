#!/usr/bin/env perl
# --uri is a real, generally meaningful flag - Getopt::Long declares it and
# evidence_add reads it - but it is read in exactly one place in the whole
# engine. Every other command that accepted it silently dropped the value:
# tira.release.record --uri https://... exited 0 and wrote an evidence entry
# with an empty uri, the given link gone with no refusal to say so. The same
# class %OPTION_READ_BY already exists to catch - sdlc_gate (TKT-281) and
# comment (TKT-302) both shipped in this exact state before the table caught
# them. TKT-431.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );

my $tira = Tira->new;
$tira->project_new(
    name => 'Linked', dir => $root, members => ['claude'],
    sow_prefix => 'LKS', epic_prefix => 'LKE', ticket_prefix => 'LKT',
);

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    $ENV{TIRA_AUTHOR} = 'claude';
    my $status = Tira::CLI->run( command => $command, type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Carries a link' );

# --- the bug report's own scenario: release.record silently dropped --uri --
my ( $status, $out, $err ) = cli(
    'release.record', '--ref', $card->{ref}, '--gate', 'Release gate', '--result', 'pass',
    '--details', 'Suite green', '--evidence', 'Full suite run',
    '--uri', 'https://ci.example.com/build/999', '--fix-version', '1.0',
);
isnt( $status, 0, 'release.record refuses --uri instead of silently dropping it' );
like( $err, qr/--uri/, 'naming the option it will not act on' );
like( $err, qr/tira\.evidence\.add/, 'and naming the command that reads it' );

my $record = $tira->record_show( project => $root, ref => $card->{ref} );
is( scalar @{ $record->{evidence} }, 0, 'and nothing was written at all - not even the gate the same call also carried' );
is( $record->{fix_version}, undef, 'the whole call is refused, not half-applied' );

# --- the command that DOES read it still works, for contrast ---------------
( $status, $out, $err ) = cli(
    'evidence.add', '--ref', $card->{ref}, '--summary', 'Build log',
    '--uri', 'https://ci.example.com/build/1000',
);
is( $status, 0, 'evidence.add still accepts --uri' ) or diag($err);
$record = $tira->record_show( project => $root, ref => $card->{ref} );
is( $record->{evidence}[0]{uri}, 'https://ci.example.com/build/1000', 'and actually stores it' );

done_testing;

__END__

=head1 NAME

299-a-link-nothing-was-listening-for.t - --uri refuses on every command but evidence.add

=head1 DESCRIPTION

Covers TKT-431: --uri is read only by evidence_add, so every other command
that accepted it (release.record among them) silently dropped the value.
%OPTION_READ_BY now refuses --uri on any command that does not read it,
naming tira.evidence.add as the one that does - the same shape TKT-281 and
TKT-302 already established for --sdlc-gate and --comment.

=cut
