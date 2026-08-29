#!/usr/bin/env perl
# Only the process that launched the board may replace it.
#
# The restart is called from the closure that serves /data. Under a pre-forked
# server that closure runs in a worker, and a worker is not the board: the
# master owns the listening socket, so a worker that execs into a fresh
# dashboard cannot bind the port and dies. The master forks a replacement, the
# next poll does the same thing, and the board never upgrades.
#
# Reproduced on an isolated board on 2026-08-13, three measurements:
#
#   no skew, three polls          - no worker replaced
#   a skew, ninety idle seconds   - no worker replaced
#   a skew, ONE poll              - a worker replaced, and curl got nothing
#                                   at all: "data 000 in 0.013s"
#
# and the server said what happened to it in its own log:
#
#   Starman::Server ... starting! pid(393051)
#   Cannot bind and listen to TCP port 7911 on 127.0.0.1 [Address already in use]
#   Received QUIT. Running a graceful shutdown
#
# His four boards had been doing that every sixty-five seconds since Wednesday,
# losing one request a minute. It is also why he reported that the page does
# not refresh by itself: the poll returns nothing, so the page keeps what it
# had, and clicking the browser's refresh button works because that asks for
# the page rather than for /data.
#
# So a restart is attempted only by the process that launched the board. Under
# Starman that is never the one serving /data, which means a served board does
# not upgrade itself - and rather than failing silently once a minute it says
# so, in the payload the page already reads.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
# Tira::CLI::Serve holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Serve;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T10:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Serving', dir => $root, columns => ['Backlog, Doing'] );
$tira->create_record( project => $root, type => 'ticket', title => 'Something' );

# Served the way the board serves it, with the data closure driven the way the
# page drives it. $args{worker} makes the closure believe it is running
# somewhere other than the process that launched the board, which is what a
# pre-forked worker is.
sub serve {
    my (%args) = @_;
    my @restarted;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    my ( $captured, $payload );
    {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        no warnings 'redefine';
        local *Tira::installed_version = sub { $args{disk} } if exists $args{disk};
        local *Tira::CLI::Serve::_version_on_disk = sub { $args{disk} } if exists $args{disk};
        local *Tira::CLI::Serve::_serving_pid = sub { $args{worker} ? -1 : $$ };
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
            command => 'dashboard', type => 'ticket',
            argv => [ '-o', 'browser' ],
            tira => $tira,
            browser_server => sub { my %given = @_; $captured = \%given; return 1 },
            restarter => sub { push @restarted, [@_]; return 1 },
        ) };
        $payload = $captured->{data}->() if $captured;
    }
    return ( \@restarted, decode_json($payload), $err );
}

# --- the launcher still restarts -------------------------------------------
#
# Nothing here may take away the feature. A board started in a way that lets it
# replace itself still does when new code is installed under it.

{
    my ($restarted) = serve( disk => '9.99' );
    is( scalar @{$restarted}, 1, 'the process that launched the board still restarts into new code' );
}

# --- a worker does not ------------------------------------------------------
#
# The whole bug in one assertion. This exec is what killed a worker a minute
# for twenty hours.

{
    my ($restarted) = serve( disk => '9.99', worker => 1 );
    is( scalar @{$restarted}, 0,
        'a worker never execs, because a worker cannot become the board' );
}

# --- and it says so, rather than failing quietly ----------------------------
#
# A board that cannot upgrade itself and does not say so is the thing that ran
# for twenty hours. The page already reads this payload every minute.

{
    my ( undef, $payload ) = serve( disk => '9.99', worker => 1 );
    is( $payload->{_stale}, '9.99',
        'the payload names the version installed under the board it cannot become' );
    is( $payload->{_version}, $Tira::VERSION, 'while still saying which version is serving' );
}

# --- and says nothing when there is nothing to say --------------------------

{
    my ( undef, $payload ) = serve( disk => $Tira::VERSION, worker => 1 );
    ok( !exists $payload->{_stale},
        'a board running the code that is installed says nothing about it' );
}

{
    my ( undef, $payload ) = serve( disk => undef, worker => 1 );
    ok( !exists $payload->{_stale},
        'and a version it cannot read is not reported as a newer one' );
}

# --- and the page has somewhere to put it -----------------------------------
#
# A payload nobody renders is the same silence in a different file. The rule
# from t/121 applies: an element the page carries must have the code that fills
# it, or it is decoration.

{
    my $data = $tira->dashboard( project => $root, with_title => 1 );
    my $page = $tira->format_output( $data, output => 'table', project => $root,
        live => 1, with_title => 1 );
    like( $page, qr/class="stale-notice"/, 'the served board carries a place to say it' );
    like( $page, qr/markStale/, 'and the code that fills it' );
    like( $page, qr/markStale\(data\._stale\)/,
        'called with what the payload actually carries, on every refresh' );
    like( $page, qr/restart this board/,
        'saying what to do about it, not merely that something is wrong' );
}

# --- the launcher is remembered, not asked for ------------------------------
#
# _serving_pid answers with the pid of the process that set the board up. It is
# recorded before the server forks, because after the fork there is no way to
# tell a worker from its master by asking the process itself.

is( Tira::CLI::Serve::_serving_pid(), $$,
    'outside a served board, the serving process is this one' );

done_testing;

__END__

=head1 NAME

124-a-worker-cannot-restart-the-board.t - only the launcher may replace the board

=head1 DESCRIPTION

The version check runs in the closure that serves C</data>, which under a
pre-forked server runs in a worker. A worker that execs into a fresh dashboard
cannot bind the port its own master holds, so it dies, the master forks a
replacement, and the next poll repeats it. Four boards did that every
sixty-five seconds for twenty hours without ever upgrading, and each attempt
cost the request that triggered it - which is why the page appeared to stop
refreshing by itself.

A restart is now attempted only by the process that launched the board. Under
Starman that is never the process serving C</data>, so a served board does not
replace itself - and says so in the payload the page already reads, rather than
failing silently once a minute.

=cut
