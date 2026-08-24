#!/usr/bin/env perl
# TKT-496. Prerequisite for TKT-494 ("It can be multiple entries", Michael's
# own words). column_roles_set stored one column per role - 'entry' meant
# exactly one column, and record.create's dispatch (TKT-428) read it as a
# scalar. Scoped to 'entry' alone: no other role needs more than one column
# for any use case this project has.

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
    name => 'ManyEntries', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'implement', 'done' ],
    sow_prefix => 'MES', epic_prefix => 'MEE', ticket_prefix => 'MET',
);

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => $command, type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

# --- declaring 'entry' twice accumulates rather than the last one winning --

{
    my ( $status ) = cli( 'column.roles', '--role', 'entry=backlog', '--role', 'entry=planning' );
    is( $status, 0, 'declaring entry twice is accepted' );
    my $roles = $tira->column_roles( project => $root, type => 'ticket' );
    is_deeply( $roles->{entry}, [ 'backlog', 'planning' ], 'both are kept, in the order given' );
}

# --- a create with no --column lands in the first declared entry column ----

{
    my ( $status, $out ) = cli( 'record.create', '--title', 'No column named', '-o', 'json' );
    is( $status, 0, 'creating with no --column still succeeds' ) or diag($out);
    like( $out, qr/"column"\s*:\s*"backlog"/, 'and lands in the first declared entry column' );
}

# --- naming any declared entry column explicitly succeeds ------------------

{
    my ( $status, $out ) = cli( 'record.create', '--title', 'Second entry', '--column', 'planning', '-o', 'json' );
    is( $status, 0, 'creating in the second declared entry column succeeds' ) or diag($out);
    like( $out, qr/"column"\s*:\s*"planning"/, 'and lands there, not the first' );
}

# --- naming a column that is not one of the declared entries refuses -------

{
    my ( $status, undef, $err ) = cli( 'record.create', '--title', 'Not an entry', '--column', 'implement' );
    isnt( $status, 0, 'a column that is not any declared entry is refused' );
    like( $err, qr/entry columns are backlog, planning/, 'naming both entry columns, plural' );
}

# --- a board with exactly one entry column is completely unaffected --------

{
    my $solo_root = File::Spec->catdir( $tmp, 'solo' );
    my $solo = Tira->new;
    $solo->project_new(
        name => 'OneEntry', dir => $solo_root, members => ['claude'],
        columns => [ 'backlog', 'planning', 'implement', 'done' ],
        sow_prefix => 'OES', epic_prefix => 'OEE', ticket_prefix => 'OET',
    );
    $solo->column_roles_set( project => $solo_root, type => 'ticket', roles => { entry => 'planning' } );

    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $solo_root;
    my $status = Tira::CLI->run( command => 'record.create', type => 'ticket', tira => $solo,
        argv => [ '--title', 'Still one entry', '-o', 'json' ] );
    is( $status, 0, 'a single-entry board still creates without --column' );
    like( $out, qr/"column"\s*:\s*"planning"/, 'and still lands in its one declared entry, exactly as before TKT-496' );
}

done_testing;

__END__

=head1 NAME

374-more-than-one-way-in.t - a board can start new cards in more than one column

=head1 DESCRIPTION

C<column_roles_set> stored one column per role, so 'entry' meant exactly
one column and C<record.create> could only ever land a card there or
refuse. C<--role entry=X> given more than once now accumulates into a
list rather than the last one silently winning; C<record.create> with no
C<--column> lands in the first declared entry, and naming any of the
declared entries explicitly succeeds. Every other role, and every board
with zero or one entry column, is unaffected.

=cut
