#!/usr/bin/env perl
# TKT-426 refuses a move that skips ahead of the board's declared column
# order - but a card created directly into implement, or verify, or done
# never needs to be moved there at all, so the chain check never sees it.
# create_record validates --column only for existing, not for being the
# board's intended starting point. The owner's own instruction (TG msg
# 4126-4128): a policy names which column is the valid entry point for new
# cards, and create refuses anything else - reusing the existing
# tira.column.roles vocabulary ('which column is the backlog' is already
# named there for every board) rather than a new mechanism. TKT-428.

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
    name => 'Entries', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'doc', 'implement', 'done' ],
    sow_prefix => 'ENS', epic_prefix => 'ENE', ticket_prefix => 'ENT',
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

# --- before any entry role is configured: unchanged from today -------------
my ( $status, $out, $err ) = cli( 'record.create', '--title', 'No role configured yet', '--column', 'implement' );
is( $status, 0, 'with no entry role configured, --column is unrestricted, as before' ) or diag($err);

# --- configure planning as the entry point ----------------------------------
$tira->column_roles_set( project => $root, type => 'ticket', roles => { entry => 'planning' } );

# --- creating with --column set to the entry point succeeds ----------------
( $status, $out, $err ) = cli( 'record.create', '--title', 'Starts correctly', '--column', 'planning' );
is( $status, 0, 'creating in the declared entry column succeeds' ) or diag($err);

# --- creating with no --column defaults to the entry point, not backlog ----
( $status, $out, $err ) = cli( 'record.create', '--title', 'Uses the default' );
is( $status, 0, 'creating with no --column still succeeds' ) or diag($err);
my ($created) = grep { $_->{title} eq 'Uses the default' } @{ $tira->record_list( project => $root, type => 'ticket' ) };
is( $created->{column}, 'planning', 'and lands in the configured entry point, not the hardcoded backlog' );

# --- creating with --column set to anything else refuses -------------------
( $status, $out, $err ) = cli( 'record.create', '--title', 'Starts in the wrong place', '--column', 'implement' );
isnt( $status, 0, 'creating outside the entry column refuses' );
like( $err, qr/planning/, 'naming the correct entry column' );
my ($not_created) = grep { $_->{title} eq 'Starts in the wrong place' } @{ $tira->record_list( project => $root, type => 'ticket' ) };
ok( !$not_created, 'and nothing was created at all' );

# --- backlog itself, no longer the entry point, is refused too -------------
( $status, $out, $err ) = cli( 'record.create', '--title', 'Backlog is not special anymore', '--column', 'backlog' );
isnt( $status, 0, 'even backlog is refused once a different entry column is declared' );
like( $err, qr/planning/, 'still naming the real entry column' );

# --- the direct engine call (the dashboard's own path) stays unrestricted --
# create_record's own return never carries column - it is the directory the
# record sits in, not a stored field - so read it back the way record_show
# does, to confirm the entry role had no say over where it actually landed.
my $direct = $tira->create_record( project => $root, type => 'ticket', title => 'Dashboard bypass', column => 'implement' );
is( $tira->record_show( project => $root, ref => $direct->{ref} )->{column}, 'implement',
    'a direct create_record call is not restricted by the entry role at all' );

done_testing;

__END__

=head1 NAME

302-a-card-that-started-somewhere-else.t - create refuses a card outside its entry column

=head1 DESCRIPTION

Covers TKT-428: a configured entry role (tira.column.roles --role entry=COLUMN)
makes record.create refuse any --column other than the entry column, and
default to it when --column is omitted. Unconfigured boards are unaffected.
The check lives in the CLI dispatch layer only - a direct create_record call,
the dashboard's own path, is untouched.

=cut
