#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use File::Spec;
use File::Temp qw(tempdir);

use lib 'lib';
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'served' );
my $tira = Tira->new;
$tira->project_new( name => 'Served', dir => $root, columns => ['backlog, doing'] );
my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );

# One connection that never finishes its request stopped the board answering
# anybody. Reproduced deliberately before this was written: 200, then nothing
# at all while a connection was held open, then 200 again the moment it was
# released - which is exactly what his board was doing with its port open, its
# process alive and nothing coming back.
#
# The cause is the server. HTTP::Server::PSGI handles one connection at a time,
# which was a reasonable choice when a board was a page somebody loaded now and
# then. This board polls itself every sixty seconds, fetches a work log when
# somebody expands it, and sits open on a phone all day.

my @chosen;
{
    require Plack::Runner;
    no warnings 'redefine';
    local *Plack::Runner::new = sub { return bless {}, 'Plack::Runner' };
    local *Plack::Runner::parse_options = sub { my ( undef, @o ) = @_; @chosen = @o; return };
    local *Plack::Runner::run = sub { return 1 };

    Tira::DashboardWeb->serve( host => '127.0.0.1', port => 7999,
        render => sub { '' }, data => sub { '' }, %providers );
}

my %option = @chosen[ 0 .. $#chosen ];
isnt( $option{'--server'}, 'HTTP::Server::PSGI',
    'the board is not served by something that handles one connection at a time' );
is( $option{'--server'}, 'Starman',
    'but by the one that does not stop answering because somebody is slow' );

# And with a certificate it is the same server, so there is one way the board
# is served rather than two that behave differently under load.
{
    @chosen = ();
    no warnings 'redefine';
    local *Plack::Runner::new = sub { return bless {}, 'Plack::Runner' };
    local *Plack::Runner::parse_options = sub { my ( undef, @o ) = @_; @chosen = @o; return };
    local *Plack::Runner::run = sub { return 1 };

    Tira::DashboardWeb->serve( host => '127.0.0.1', port => 7999,
        render => sub { '' }, data => sub { '' }, %providers,
        ssl_cert => '/tmp/board.crt', ssl_key => '/tmp/board.key' );
    my %secured = @chosen[ 0 .. $#chosen ];
    is( $secured{'--server'}, 'Starman', 'over TLS it is the same server as without' );
    ok( ( grep { $_ eq '--enable-ssl' } @chosen ), 'with TLS turned on' );
}

done_testing;

__END__

=head1 NAME

105-board-keeps-answering.t - one slow connection must not stop the board

=head1 DESCRIPTION

His board was found listening, its process alive, and answering nothing: a
connection sat queued and was never accepted, and a restart fixed it instantly.
A board that accepts a connection and never answers looks exactly like a board
that is fine, until somebody tries to load it - and he reads this board instead
of asking for progress, so the last thing he saw stays on his screen.

The server handled one connection at a time. Now there is one server for both
plain and TLS, so the board behaves the same way under load however it is
served.

=cut
