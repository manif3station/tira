#!/usr/bin/env perl
# TKT-517: tira.onboard -o browser dispatches to a disposable onboarding
# server instead of the interactive STDIN wizard, on a dynamically-picked
# free port by default, and reuses the same project-creation path project.new
# and the CLI wizard already reach. The injectable onboard_browser_server
# seam mirrors t/17's browser_server seam for tira.dashboard.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-25T12:00:00Z' } );

sub onboard_cli {
    my (@argv) = @_;
    my ( $out, $err, @calls ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run(
        command => 'onboard', argv => \@argv, tira => $tira,
        onboard_browser_server => sub { push @calls, { @_ }; return 1 },
    );
    return ( $status, $out, $err, \@calls );
}

my ( $status, $out, $err, $calls ) = onboard_cli( '-o', 'browser' );
is( $status, 0, 'onboard -o browser succeeds without prompting on STDIN' );
is( $out, '', 'nothing is dumped to stdout' );
is( $calls->[0]{host}, '127.0.0.1', 'defaults to loopback, not every interface' );
ok( $calls->[0]{port} >= 1 && $calls->[0]{port} <= 65535, 'and a real, dynamically-picked port' );
isnt( $calls->[0]{port}, 7899, 'not the dashboard-server fixed default' );
ok( ref $calls->[0]{create} eq 'CODE', 'and a create provider to actually make the project' );

( $status, $out, $err, $calls ) = onboard_cli( '-o', 'browser=127.0.0.1:4321' );
is( $status, 0, 'an explicit endpoint is honored' );
is( $calls->[0]{port}, 4321, 'with the given port, not a dynamic one' );

my $root = File::Spec->catdir( $tmp, 'onboarded' );
( $status, $out, $err, $calls ) = onboard_cli( '-o', 'browser' );
my $summary = $calls->[0]{create}->( { name => 'Onboarded', dir => $root, members => ['ada'] } );
is( $summary->{project}{name}, 'Onboarded', 'the create provider actually creates the project' );
ok( -d $root, 'on disk, at the given directory' );
my $listed = $tira->project_show( project => $root );
is( $listed->{name}, 'Onboarded', 'reachable the normal way afterward' );

eval { $calls->[0]{create}->( { name => '', dir => File::Spec->catdir( $tmp, 'unnamed' ) } ) };
like( $@, qr/name/i, 'an invalid submission through the same path still refuses, naming why' );

# TKT-527: the disposable onboarding server has no login at all (by design -
# it is meant for exactly one submission), unlike tira.dashboard's own
# 0.0.0.0 mode, which is always login-gated. An explicit 0.0.0.0 override
# would make project creation reachable, unauthenticated, from the whole
# network - the code's own comment already says this session should never
# be reachable from another machine, so the endpoint parser must not accept
# it, not merely default away from it.
( $status, $out, $err, $calls ) = onboard_cli( '-o', 'browser=0.0.0.0:9999' );
isnt( $status, 0, '-o browser=0.0.0.0:PORT is refused for onboard' );
like( $err, qr/0\.0\.0\.0/, 'naming the address that was refused' );
is( scalar @{$calls}, 0, 'and no server was started' );

( $status, $out, $err, $calls ) = onboard_cli( '-o', 'browser=127.0.0.1:4322' );
is( $status, 0, '127.0.0.1 with an explicit port still works after the fix' );
is( $calls->[0]{host}, '127.0.0.1', 'unaffected' );

( $status, $out, $err, $calls ) = onboard_cli( '-o', 'browser' );
is( $status, 0, 'the plain default still works after the fix' );
is( $calls->[0]{host}, '127.0.0.1', 'still defaults to loopback' );

done_testing;

__END__

=head1 NAME

393-onboard-picks-up-a-browser.t - tira.onboard -o browser's CLI dispatch

=head1 DESCRIPTION

TKT-517: confirms tira.onboard -o browser never touches the interactive
STDIN wizard, defaults to a dynamically-picked free port on 127.0.0.1,
honors an explicit endpoint, and hands the onboarding server a create
provider that reaches the exact same project-creation path project.new and
the CLI wizard already use.

=cut
