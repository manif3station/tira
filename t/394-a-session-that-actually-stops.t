#!/usr/bin/env perl
# TKT-517's own ATDD names this explicitly acceptable: "Plack::Test or a real
# Starman child process". t/392 covers the form/validate/create/stop contract
# through Plack::Test; this is the real-process half - a genuine fork running
# Tira::CLI->run(command => 'onboard', -o browser=...) end to end, checked
# with real HTTP requests, proving the disposable server actually answers and
# then actually stops answering - not just that a flag flipped in memory.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use HTTP::Tiny;
use POSIX ':sys_wait_h';
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

sub free_port {
    my $socket = IO::Socket::INET->new(
        Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp' )
      or die "Could not find a free port: $!\n";
    my $port = $socket->sockport;
    $socket->close;
    return $port;
}

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'zen' );
my $tira = Tira->new;
my $port = free_port();

my $pid = fork();
die "Cannot fork: $!\n" if !defined $pid;
if ( $pid == 0 ) {
    open STDOUT, '>', File::Spec->devnull or exit 1;
    open STDERR, '>', File::Spec->devnull or exit 1;
    Tira::CLI->run(
        command => 'onboard', argv => [ '-o', "browser=127.0.0.1:$port" ], tira => $tira,
    );
    exit 0;
}

my $ua   = HTTP::Tiny->new( timeout => 2 );
my $base = "http://127.0.0.1:$port/";

my $up = 0;
for ( 1 .. 50 ) {
    my $response = $ua->get($base);
    if ( $response->{success} ) { $up = 1; last }
    select( undef, undef, undef, 0.1 );
}
ok( $up, 'the disposable onboarding server actually comes up' ) or diag("gave up waiting on 127.0.0.1:$port");

SKIP: {
    skip 'server never came up, nothing further to check', 3 if !$up;

    my $form = $ua->get($base);
    like( $form->{content}, qr/Project name/i, 'and serves the real form' );

    my $post = $ua->post_form( $base,
        { name => 'Zen', dir => $root, members => 'ada', sow_prefix => 'ZNS', epic_prefix => 'ZNE',
          ticket_prefix => 'ZNT' } );
    is( $post->{status}, 200, 'a valid submission over the wire succeeds' );
    like( $post->{content}, qr/Thank you for using Tira/i, 'with the real thank-you page' );
}

ok( -d $root, 'and the project now exists on disk' ) if $up;
my $created = eval { $tira->project_show( project => $root ) };
is( $created && $created->{name}, 'Zen', 'reachable the normal way, same as any project.new' ) if $up;

my $down = 0;
for ( 1 .. 40 ) {
    my $response = $ua->get($base);
    if ( !$response->{success} ) { $down = 1; last }
    select( undef, undef, undef, 0.1 );
}
ok( $down, 'a further request after success fails to connect - the server has really stopped' );

waitpid( $pid, 0 );

done_testing;

__END__

=head1 NAME

394-a-session-that-actually-stops.t - a real onboarding server, started, used, and stopped

=head1 DESCRIPTION

TKT-517: forks a real child process running C<Tira::CLI-E<gt>run(command =E<gt>
'onboard', -o browser=...)>, drives it with genuine HTTP requests
(C<HTTP::Tiny>, no mocking), and confirms the whole chain - CLI dispatch,
C<Tira::OnboardWeb>'s form and create provider, and the disposable server's
self-stop - end to end, including that a request made after a successful
creation genuinely fails to connect rather than merely reading a flag.

=cut
