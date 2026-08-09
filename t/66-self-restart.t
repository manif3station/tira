#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-09T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Restart', dir => $root, columns => ['Backlog, Doing'] );
$tira->create_record( project => $root, type => 'ticket', title => 'Something' );

# The version this process is running is not necessarily the one on disk: a
# dashboard left open for a week is serving whatever it started with.
is( Tira::installed_version(), $Tira::VERSION,
    'the installed version matches the running one in a clean checkout' );

# The data closure must be exercised while the mocked version is still in
# scope, or the test proves nothing about what the server would have seen.
sub serve {
    my (%args) = @_;
    my @restarted;
    my $captured;
    my $payload;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    my $status;
    {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        no warnings 'redefine';
        local *Tira::installed_version = sub { $args{installed} } if exists $args{installed};
        $status = Tira::CLI->run(
            command => 'dashboard', type => 'ticket',
            argv => [ '--project', $root, '-o', 'browser' ],
            tira => $tira,
            browser_server => sub { my %given = @_; $captured = \%given; return 1 },
            restarter => sub { push @restarted, [@_]; return 1 },
        );
        $payload = $captured->{data}->() if $captured;
    }
    return ( $status, $captured, \@restarted, $payload );
}

# Nothing has changed, so nothing restarts.
{
    my ( $status, $served, $restarted, $body ) = serve();
    is( $status, 0, 'the board serves' );
    my $payload = decode_json($body);
    is( $payload->{_version}, $Tira::VERSION,
        'the data says which version is actually serving it' );
    is_deeply( $restarted, [], 'and an unchanged version restarts nothing' );
}

# Somebody installs a new Tira under a running dashboard.
{
    my ( $status, $served, $restarted ) = serve( installed => '9.99' );
    is( scalar @{$restarted}, 1, 'a new version on disk restarts the server' );
    is_deeply( $restarted->[0], [ '--project', $root, '-o', 'browser' ],
        'with the same arguments it was started with, so it comes back the same board' );
}

# An unreadable .env must not put the server in a restart loop.
{
    my ( $status, $served, $restarted ) = serve( installed => undef );
    is_deeply( $restarted, [], 'an unknown version is treated as no change, not as an update' );
}

# The page carries the version it was built by, so it can tell when the server
# has moved on. It reloads only then - reloading while the old process still
# serves would just fetch the same page again.
my $html = $tira->format_output(
    $tira->dashboard( project => $root, type => 'ticket', summary => 1 ),
    output => 'table', project => $root, live => 1 );
like( $html, qr/data-version="\Q$Tira::VERSION\E"/, 'the page records the version that built it' );
like( $html, qr/data\._version&&data\._version!==document\.documentElement\.dataset\.version/,
    'and compares it with the one actually serving' );
like( $html, qr/location\.reload\(\);return\}/, 'reloading when they differ' );

# The static board has no server to ask, so it must not carry the check.
my $static = $tira->format_output(
    $tira->dashboard( project => $root, type => 'ticket', summary => 1 ),
    output => 'table', project => $root );
unlike( $static, qr/data\._version/,
    'a static board does not poll for a version it can never be told about' );

# The restart itself. exec replaces this process, so it is exercised in a child
# that is allowed to be replaced - proving it really does re-run the command
# rather than merely being called.
{
    my $script = File::Spec->catfile( $tmp, 'restarted.pl' );
    open my $fh, '>', $script or die $!;
    # Escaped, or the outer string interpolates this test's own (empty) \@ARGV
    # when the file is written, and the child would prove nothing.
    print {$fh} 'print qq{restarted with: @ARGV\n}; exit 0;' . "\n";
    close $fh;

    my $marker = File::Spec->catfile( $tmp, 'proof.txt' );
    my $pid = fork();
    die "cannot fork: $!" if !defined $pid;
    if ( !$pid ) {
        open my $out, '>', $marker or exit 1;
        open STDOUT, '>&', $out or exit 1;
        local $0 = $script;
        Tira::CLI::_restart_into( 'one', 'two' );
        exit 99;    # only reached if exec failed to replace us
    }
    waitpid $pid, 0;
    my $exit = $? >> 8;
    is( $exit, 0, 'the restart replaced the process rather than returning' );
    open my $in, '<', $marker or die $!;
    my $said = do { local $/; <$in> };
    close $in;
    like( $said, qr/restarted with: one two/,
        'and re-ran the command with the arguments it was given' );
}

# A path it cannot vouch for is refused rather than executed.
{
    no warnings 'redefine';
    local $0 = "bad\x00path";
    is( Tira::CLI::_restart_into('x'), 0, 'an unsafe script path refuses to restart' );
}

done_testing;

__END__

=head1 NAME

66-self-restart.t - DD-488 a dashboard that picks up a new Tira by itself

=head1 DESCRIPTION

A dashboard left open is serving whatever Tira it started with, so
updating meant visiting every open board and restarting it by hand.
Proves the server notices a new version on disk and re-executes itself
with the arguments it was started with, that an unchanged or unreadable
version does not, and that the page reloads only once the version
actually being served differs from the one that built it - reloading
any earlier would just fetch the same old page from the same old
process.

=cut
