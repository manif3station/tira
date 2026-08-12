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
my $tira = Tira->new( clock => sub { '2026-08-11T09:00:00Z' } );

my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Gated', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'GTS', epic_prefix => 'GTE', ticket_prefix => 'GTT',
);

sub run {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run(
            command => shift(@argv), tira => $tira,
            argv => [ '--project', $root, @argv ],
        );
    };
    return ( $status, $out, $err );
}

# --- a project with no repository ----------------------------------------

# Refusing here rather than writing hooks nothing will ever run: a gate
# installed where git is not looking is a gate that exists only in a directory
# listing.
my ( $status, undef, $err ) = run('gates.install');
isnt( $status, 0, 'installing into something that is not a repository is refused' );
like( $err, qr/git/i, 'and says why' );

# --- installing ----------------------------------------------------------

mkdir File::Spec->catdir( $root, '.git' );
mkdir File::Spec->catdir( $root, '.git', 'hooks' );

( $status, my $out ) = run( 'gates.install', '-o', 'json' );
is( $status, 0, 'installing into a repository succeeds' );

my $hooks = File::Spec->catdir( $root, '.git', 'hooks' );
for my $hook (qw(commit-msg pre-push)) {
    my $path = File::Spec->catfile( $hooks, $hook );
    ok( -e $path, "the $hook gate is in place" );

    # Executability is what makes git run a hook on a POSIX system. Windows has
    # no such bit - git there runs hooks through its own shell - so the thing
    # worth asserting is different, not absent.
    ok( ( $^O eq 'MSWin32' ? -s $path : -x $path ),
        "and is executable, which is the only reason git will run it" );
}

# --- installing twice ----------------------------------------------------

# Somebody will run this again. It must not break, and it must not end up with
# two copies of anything.
( $status ) = run( 'gates.install', '-o', 'json' );
is( $status, 0, 'installing a second time is safe' );
for my $hook (qw(commit-msg pre-push)) {
    my $path = File::Spec->catfile( $hooks, $hook );
    ok( ( $^O eq 'MSWin32' ? -s $path : -x $path ), "and the $hook gate is still there" );
}

# --- what the gates actually check ---------------------------------------

# Read rather than run, because running them means running a whole test suite
# inside a test. What matters here is that the installed file is the real gate
# and not a stub that would pass anything.
for my $hook (qw(commit-msg pre-push)) {
    open my $fh, '<', File::Spec->catfile( $hooks, $hook ) or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;

    like( $body, qr/set -euo pipefail/, "the $hook gate stops at the first failure" );
    unlike( $body, qr/exit 0\s*\z/, "and does not simply succeed at the end" );
}

{
    open my $fh, '<', File::Spec->catfile( $hooks, 'commit-msg' ) or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    like( $body, qr/SOW\|EPC\|TKT|tira\./, 'the commit gate looks for a card reference' );
    like( $body, qr/backlog/, 'and refuses a card that is not being worked on' );
}

{
    open my $fh, '<', File::Spec->catfile( $hooks, 'pre-push' ) or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    like( $body, qr/police|tira\.police/, 'the push gate asks police what it thinks' );
    like( $body, qr/refusing rather than skipping/,
        'and fails closed when something it depends on is gone' );
    like( $body, qr/could not read the board/,
        'and treats a board it cannot read as a refusal, not a pass' );
}

# --- the tools it needs travel with it -----------------------------------

# A gate that shells out to something the project does not have is a gate that
# fails on the first machine that is not this one.
{
    open my $fh, '<', File::Spec->catfile( $hooks, 'pre-push' ) or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    unlike( $body, qr{tools/card-holes|tools/docs-match-code},
        'the installed gate calls Tira rather than scripts that live in one repository' );
}

done_testing;

__END__

=head1 NAME

92-installable-gates.t - Tira installs its own gates, rather than each agent writing them

=head1 DESCRIPTION

The gates that catch a commit naming no card, and a push with the board in a
mess, existed only as shell scripts in one repository on one machine. That is
scaffolding rather than a product: another project adopting Tira got none of
it, and another agent writing its own would get it subtly different.

So Tira installs them. The test reads the installed files rather than running
them, because running the push gate means running an entire test suite inside a
test - and what matters is that the installed file is the real gate rather than
a stub that would pass anything.

The last check is the one that decides whether this is a product. The installed
gate must call Tira, not scripts that happen to live in this repository. A gate
that shells out to something the project does not have is a gate that fails on
the first machine that is not this one.

=cut
