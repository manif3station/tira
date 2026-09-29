#!/usr/bin/env perl
# TKT-1192. lib/Tira/CLI.pm:912-914 - the human-output print branch for
# record.list --sum FIELD when --count is NOT also given - has never been
# exercised by any test. Every existing --sum test (t/1162, t/1169, t/1170)
# calls Tira->record_list directly at the engine layer; every CLI-level
# --sum test (t/733's style) passes -o json, which takes format_output's
# generic hashref path and never reaches this human-output print statement.
#
# Self-found while diagnosing TKT-1191's gate.run refusal: gate.run checks
# every module under lib/, not only the ones a ticket touches, so this
# permanent gap blocked gate.run for every ticket on the board.
#
# WRITTEN RED.

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
my $tira = Tira->new( clock => sub {'2026-09-29T01:00:00Z'} );
$tira->project_new(
    name => 'A sum the CLI never printed', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'CSS', epic_prefix => 'CSE', ticket_prefix => 'CST',
);
$tira->project_update( project => $root, numeric_field => 'points' );

$tira->create_record( project => $root, type => 'ticket', title => 'Five points', numeric_value => 5 );
$tira->create_record( project => $root, type => 'ticket', title => 'Seven points', numeric_value => 7 );

# --- exercised through the real CLI dispatch, human output, no --count -----

sub run_cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => 'record.list', type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

my ( $status, $out, $err ) = run_cli( '--sum', 'points' );
is( $status, 0, 'ticket.list --sum runs cleanly through the real CLI dispatch with no --count' );
like( $out, qr/^sum: 12$/m, 'the CLI prints the sum line itself, not just the engine-level hash' )
  or diag("got: $out");
like( $out, qr/Five points/, 'the ordinary per-record human dump still runs, unwrapped from the {sum,records} hash' );
like( $out, qr/Seven points/, 'both records are present in the unwrapped dump' );

done_testing;

__END__

=head1 NAME

1192-a-sum-the-cli-never-printed.t - the CLI's own --sum-without-count human-output line, finally covered

=head1 DESCRIPTION

TKT-1192. C<lib/Tira/CLI.pm:912-914> prints C<sum: N> for C<record.list
--sum FIELD> in human output when C<--count> is not also given, then
unwraps C<$result> back to the plain record array so the ordinary
per-record dump below runs unchanged. This is the sibling of TKT-1166's
C<--sum>+C<--count> branch (lines 898-901, tested at the CLI level in
t/1169) and TKT-1167's C<--sum>+C<--refs-only> fix (t/1170) - but neither
of those, nor t/1162's own engine-level coverage, ever drove a plain
C<--sum> through the real CLI dispatch with human output. This test does.

=cut
