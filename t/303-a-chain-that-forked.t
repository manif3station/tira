#!/usr/bin/env perl
# TKT-426's chain check refuses a forward move that skips ahead, computed
# purely from array position: the next valid column for X is
# columns[index(X)+1], a single value. That is correct for a strictly
# linear chain but cannot express a genuine fork - the owner's own example:
# a 13-stage chain ending at e2e-testing, which then forks - either the
# card is done there, or it continues through deploying, demo-regression-
# test, deployed-on-demo. A single flat declared order cannot satisfy both
# branches under strict-next enforcement (independently confirmed by
# TKT-435, a different project hitting the identical gap). TKT-430.

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
    name => 'Forked', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'e2e-testing', 'done', 'deploying', 'demo-regression-test', 'deployed-on-demo' ],
    sow_prefix => 'FKS', epic_prefix => 'FKE', ticket_prefix => 'FKT',
);

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    local $ENV{TIRA_AUTHOR} = "claude";
    my $status = Tira::CLI->run( command => $command, type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

# --- before any --next is configured: unchanged positional behavior -------
my $plain = $tira->create_record( project => $root, type => 'ticket', title => 'Plain chain' );
my ( $status, $out, $err ) = cli( 'record.move', '--ref', $plain->{ref}, '--column', 'e2e-testing' );
isnt( $status, 0, 'without a configured fork, a skip past planning still refuses' );
like( $err, qr/planning/, 'naming the single positional next column' );

# --- configure the fork: e2e-testing can go to either done or deploying ----
$tira->column_update( project => $root, type => 'ticket', name => 'e2e-testing', next => [ 'done', 'deploying' ] );

# --- branch A: non-shipping work goes straight to done ---------------------
my $branch_a = $tira->create_record( project => $root, type => 'ticket', title => 'Non-shipping work' );
cli( 'record.move', '--ref', $branch_a->{ref}, '--column', 'planning' );
cli( 'record.move', '--ref', $branch_a->{ref}, '--column', 'e2e-testing' );
( $status, $out, $err ) = cli( 'record.move', '--ref', $branch_a->{ref}, '--column', 'done' );
is( $status, 0, 'branch A: e2e-testing to done succeeds, one of the two forks' ) or diag($err);

# --- branch B: shipping work continues into deploying -----------------------
my $branch_b = $tira->create_record( project => $root, type => 'ticket', title => 'Shipping work' );
cli( 'record.move', '--ref', $branch_b->{ref}, '--column', 'planning' );
cli( 'record.move', '--ref', $branch_b->{ref}, '--column', 'e2e-testing' );
( $status, $out, $err ) = cli( 'record.move', '--ref', $branch_b->{ref}, '--column', 'deploying' );
is( $status, 0, 'branch B: e2e-testing to deploying succeeds, the other fork' ) or diag($err);
( $status, $out, $err ) = cli( 'record.move', '--ref', $branch_b->{ref}, '--column', 'demo-regression-test' );
is( $status, 0, 'and the tail past the fork remains a plain positional chain' ) or diag($err);
( $status, $out, $err ) = cli( 'record.move', '--ref', $branch_b->{ref}, '--column', 'deployed-on-demo' );
is( $status, 0, 'all the way to the second terminal column' ) or diag($err);

# --- a third destination, not in the declared fork, still refuses ----------
my $branch_c = $tira->create_record( project => $root, type => 'ticket', title => 'Neither fork' );
cli( 'record.move', '--ref', $branch_c->{ref}, '--column', 'planning' );
cli( 'record.move', '--ref', $branch_c->{ref}, '--column', 'e2e-testing' );
( $status, $out, $err ) = cli( 'record.move', '--ref', $branch_c->{ref}, '--column', 'demo-regression-test' );
isnt( $status, 0, 'skipping past the fork to a non-adjacent column still refuses' );
like( $err, qr/done/, 'naming one option' );
like( $err, qr/deploying/, 'and the other' );

# --- backward moves stay unconditional, fork or no fork --------------------
( $status, $out, $err ) = cli( 'record.move', '--ref', $branch_b->{ref}, '--column', 'e2e-testing' );
is( $status, 0, 'moving backward out of a forked destination is still always allowed' ) or diag($err);

done_testing;

__END__

=head1 NAME

303-a-chain-that-forked.t - a column can declare more than one valid next column

=head1 DESCRIPTION

Covers TKT-430: column.update --next COLUMN (repeatable) lets a column
declare an explicit set of valid next columns instead of the single
positional successor the chain check otherwise derives. An unconfigured
column keeps today's behavior. Backward moves stay unconditional.

=cut
