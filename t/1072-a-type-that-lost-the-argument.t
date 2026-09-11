#!/usr/bin/env perl
# TKT-1071. Found by the hourly bug hunt. dashboard.sow/.epic/.ticket dispatch
# to the same shared method as bare `dashboard` (lib/Tira/CLI.pm:1858), and
# the arg-preparation block that follows unconditionally sets $args{type} from
# the command name itself for the type-specific forms:
#
#   $args{type} = $1 if defined $1;
#
# $1 is always defined for dashboard.sow/.epic/.ticket (captured straight from
# the command name), so an explicit --type on one of these three is silently
# overwritten with no refusal - reproduced live against a real 2-record
# project: `dashboard.sow --type ticket -o json` served the sow board, not
# the ticket board.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Typed', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'TYS', epic_prefix => 'TYE', ticket_prefix => 'TYT',
);
$tira->create_record( project => $root, type => 'sow',    title => 'a sow' );
$tira->create_record( project => $root, type => 'ticket', title => 'a ticket' );

sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => $command, tira => Tira->new, argv => [@argv] );
    };
    return ( $status, $out, $err );
}

# --- an explicit --type on a type-fixed dashboard command is refused -------

for my $cmd (qw(dashboard.sow dashboard.epic dashboard.ticket)) {
    my ( $status, $out, $err ) = run( $cmd, '--type', 'ticket', '-o', 'json' );
    isnt( $status, 0, "$cmd --type ticket is refused, not silently accepted" );
    like( $err, qr/--type/, "and ${cmd}'s refusal names --type" );
    is( $out, '', "and $cmd prints nothing that looks like an answer" );
}

# --- the bare dashboard command still reads --type normally ----------------

my ( $status, $out ) = run( 'dashboard', '--type', 'ticket', '-o', 'json' );
is( $status, 0, 'bare dashboard --type ticket still works' );
my $data = decode_json($out);
ok( exists $data->{ticket}, 'and answers about the ticket board it was asked for' );
ok( !exists $data->{sow},   'not the sow board' );

done_testing;

__END__

=head1 NAME

t/1072-a-type-that-lost-the-argument.t - dashboard.sow/.epic/.ticket refuse an
explicit --type rather than silently discarding it

=head1 DESCRIPTION

TKT-1071. dashboard.sow/.epic/.ticket alias into the same dispatch as bare
C<dashboard>, and their type is fixed by the command name - but the
arg-preparation block that reads the command name into C<$args{type}> ran
unconditionally, silently overwriting whatever C<--type> a caller passed
with no refusal. Reproduced live: C<dashboard.sow --type ticket> served the
sow board. Now refused, naming C<--type> as the redundant flag.

=cut
