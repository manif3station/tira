#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-12T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Secured', dir => $root, members => ['michael'],
    columns => ['backlog, doing'],
    sow_prefix => 'SCS', epic_prefix => 'SCE', ticket_prefix => 'SCT',
);

# --- a certificate, made without running anything -------------------------

# Tira documents that it invokes no shell or external process, and Developer
# Dashboard makes its certificate by running openssl. That is not available
# here, so this is made by a library - which keeps the guarantee rather than
# quietly spending it on a convenience.
my $first = $tira->tls_certificate( project => $root );

ok( $first, 'a certificate can be had' );
like( $first->{certificate}, qr/BEGIN CERTIFICATE/, 'and it is a certificate' );
like( $first->{key}, qr/BEGIN (?:RSA )?PRIVATE KEY/, 'with a private key' );

ok( -f $first->{certificate_path}, 'written where the board can find it again' );
ok( -f $first->{key_path}, 'both halves' );

# The key is a secret and the filesystem is the only thing protecting it.
SKIP: {
    skip 'file modes are not meaningful on this platform', 1 if $^O eq 'MSWin32';
    my $mode = ( stat $first->{key_path} )[2] & 07777;
    is( $mode, 0600, 'and the key is readable by nobody else' );
}

# --- made once, not on every start ----------------------------------------

# A certificate that changes on every restart is one the browser warns about
# every time, which teaches somebody to click through warnings.
my $second = $tira->tls_certificate( project => $root );
is( $second->{certificate}, $first->{certificate}, 'starting again reuses the same certificate' );
is( $second->{key}, $first->{key}, 'and the same key' );

# --- outside the boards ---------------------------------------------------

# Like the journal and the search index: near the project, never inside a board
# where a scan or a content hash would trip over it.
unlike( $first->{certificate_path}, qr{[\\/](?:sow|epic|ticket)[\\/]},
    'kept out of the boards, where a scan would find it' );

# --- the option -----------------------------------------------------------

{
    my @calls;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
            command => 'dashboard.ticket', tira => $tira,
            argv => [ '-o', 'browser', '--ssl' ],
            browser_server => sub { push @calls, {@_}; return 1 },
        ) };
    }
    ok( scalar @calls, 'the browser dashboard takes --ssl' );
    ok( $calls[0]{ssl_cert}, 'and is handed a certificate to serve with' );
    ok( $calls[0]{ssl_key}, 'and its key' );

    like( $err, qr/https/i, 'and it says the board is served over HTTPS' );
    like( $err, qr/self-signed|warn/i,
        'and that the browser will complain the first time, so nobody thinks it is broken' );
}

# --- and without it nothing changes ---------------------------------------

{
    my @calls;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
            command => 'dashboard.ticket', tira => $tira,
            argv => [ '-o', 'browser' ],
            browser_server => sub { push @calls, {@_}; return 1 },
        ) };
    }
    ok( !$calls[0]{ssl_cert}, 'without --ssl the board is served exactly as before' );
}

done_testing;

__END__

=head1 NAME

101-self-signed-tls.t - serving the board over HTTPS

=head1 DESCRIPTION

The login went in this release, and the documentation had to admit that over
plain HTTP the password and the session cookie travel in clear. Michael reads
the board from his phone across the network, so that is not theoretical - and
he has since asked for a session that never expires, which makes the cookie a
credential with no end date.

The certificate is made by a library rather than by running C<openssl>, because
Tira documents that it invokes no shell or external process and that guarantee
is not worth spending on a convenience. It is made once and reused, since a
certificate that changes on every restart is one the browser warns about every
time - which teaches somebody to click through warnings, and that is the
opposite of the point.

A self-signed certificate stops somebody reading the password off the wire. It
does not stop somebody who can already stand in the middle, and the
documentation says so rather than letting anybody believe otherwise.

=cut
