#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'served' );
my $tira = Tira->new( clock => sub { '2026-08-07T16:00:00Z' } );
$tira->create_project( name => 'Served', dir => $root );

my $updated = $tira->project_update(
    project => $root, dashboard_host => 'localhost', dashboard_port => 8080,
);
is( $updated->{dashboard}{host}, 'localhost', 'the host is remembered' );
is( $updated->{dashboard}{port}, 8080, 'the port is remembered' );
is( $tira->project_show( project => $root )->{dashboard}{host}, 'localhost',
    'the remembered address survives a reload' );

is( $tira->project_update( project => $root, dashboard_host => 'any' )->{dashboard}{host},
    '0.0.0.0', 'any is the plain-language form of every interface' );
is( $tira->project_show( project => $root )->{dashboard}{port}, 8080,
    'changing only the host leaves the port alone' );

for my $case (
    [ { dashboard_host => 'example.com' }, qr/host/i, 'an unsupported host' ],
    [ { dashboard_port => 0 },             qr/port/i, 'a zero port' ],
    [ { dashboard_port => 70000 },         qr/port/i, 'a port above the range' ],
    [ { dashboard_port => 'eighty' },      qr/port/i, 'a non-numeric port' ],
) {
    my ( $args, $error, $label ) = @{$case};
    eval { $tira->project_update( project => $root, %{$args} ) };
    like( $@, $error, "$label is refused" );
}
is( $tira->project_show( project => $root )->{dashboard}{port}, 8080,
    'a refused change leaves the remembered address untouched' );

my $bare = File::Spec->catdir( $tmp, 'bare' );
$tira->create_project( name => 'Bare', dir => $bare );
ok( !exists $tira->project_show( project => $bare )->{dashboard},
    'a project that has never set an address carries none' );

sub serve_endpoint {
    my ( $project, @argv ) = @_;
    my %served;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = do { local $ENV{TIRA_HOME} = $project; Tira::CLI->run(
        command => 'dashboard', argv => [ @argv ],
        browser_server => sub { my %a = @_; @served{qw(host port)} = @a{qw(host port)}; return 1 },
    ) };
    return ( $status, \%served, $err );
}

my ( $status, $served, $err ) = serve_endpoint( $root, '-o', 'browser' );
is( $status, 0, 'serving succeeds' );
is( $served->{host}, '0.0.0.0', 'the remembered host is used when no address is given' );
is( $served->{port}, 8080, 'the remembered port is used when no address is given' );

( $status, $served, $err ) = serve_endpoint( $root, '-o', 'browser=localhost:9999' );
is( $served->{host}, 'localhost', 'an address on the command line wins over the remembered one' );
is( $served->{port}, 9999, 'including its port' );

( $status, $served, $err ) = serve_endpoint( $bare, '-o', 'browser' );
is( $served->{host}, '0.0.0.0', 'a project with no remembered address keeps the default host' );
is( $served->{port}, 7899, 'and the default port' );

( $status, my $out, $err ) = do {
    my ( $o, $e ) = ( '', '' );
    open my $so, '>', \$o or die $!;
    open my $se, '>', \$e or die $!;
    local *STDOUT = $so;
    local *STDERR = $se;
    my $s = do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
        command => 'project.update',
        argv => [ '--dashboard-host', 'localhost',
                  '--dashboard-port', '8100', '-o', 'json' ],
    ) };
    ( $s, $o, $e );
};
is( $status, 0, 'the CLI sets the address' );
is( decode_json($out)->{dashboard}{port}, 8100, 'and reports it back' );

( $status, $out, $err ) = do {
    my ( $o, $e ) = ( '', '' );
    open my $so, '>', \$o or die $!;
    open my $se, '>', \$e or die $!;
    local *STDOUT = $so;
    local *STDERR = $se;
    my $s = do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
        command => 'project.update',
        argv => [ '--dashboard-port', '99999', '-o', 'json' ],
    ) };
    ( $s, $o, $e );
};
is( $status, 2, 'an out-of-range port exits 2' );
is( $tira->project_show( project => $root )->{dashboard}{port}, 8100,
    'and leaves the remembered port alone' );

# The compact form the owner asked for.
for my $case (
    [ 'localhost:8300', 'localhost', 8300, 'host and port together' ],
    [ 'any:8400',       '0.0.0.0',   8400, 'any with a port' ],
    [ '127.0.0.1',      '127.0.0.1', 8400, 'a bare host leaves the port alone' ],
) {
    my ( $listen, $host, $port, $label ) = @{$case};
    my ( $s, $o, $e ) = do {
        my ( $out2, $err2 ) = ( '', '' );
        open my $so, '>', \$out2 or die $!;
        open my $se, '>', \$err2 or die $!;
        local *STDOUT = $so;
        local *STDERR = $se;
        my $st = do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'project.update',
            argv => [ '--listen', $listen, '-o', 'json' ] ) };
        ( $st, $out2, $err2 );
    };
    is( $s, 0, "--listen $listen is accepted ($label)" );
    my $shown = decode_json($o)->{dashboard};
    is( $shown->{host}, $host, "--listen $listen sets the host" );
    is( $shown->{port}, $port, "--listen $listen sets the port" );
}

my ( $bad_status, undef, $bad_err ) = do {
    my ( $out2, $err2 ) = ( '', '' );
    open my $so, '>', \$out2 or die $!;
    open my $se, '>', \$err2 or die $!;
    local *STDOUT = $so;
    local *STDERR = $se;
    my $st = do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'project.update',
        argv => [ '--listen', 'a:b:c', '-o', 'json' ] ) };
    ( $st, $out2, $err2 );
};
is( $bad_status, 2, 'a malformed listen address exits 2' );
like( $bad_err, qr/HOST or HOST:PORT/, 'and says the accepted shape' );

done_testing;

__END__

=head1 NAME

42-dashboard-address.t - remembered dashboard address

=head1 DESCRIPTION

Proves that a project remembers the address its live dashboard should
listen on: the host and port persist and are reported, C<any> is the
plain-language form of every interface, invalid values are refused where
they are set rather than where they are used, an address given on the
command line still wins, and a project that has never set one keeps the
original default.

=cut
