#!/usr/bin/env perl
# The workers are handed a board they can open without asking anybody.
#
# Reported by the owner on 2026-08-15: "d2 tira.dashboard -o browser
# --no-session-expire" binds the port and then every request dies in
# before_request with "Hook error: Cannot resolve project path 'tira'".
#
# A board may be referred to by something other than its path. That is
# deliberate and it is not a fallback: the agent working a project is never told
# where the board actually sits, so it cannot go round the CLI and edit the
# files. discover_project resolves such a reference through a path_resolver, and
# the CLI installs one.
#
# dashboard.psgi builds a plain Tira object, which has no resolver, and serve()
# passed its argument through untouched. So the parent resolved nothing and the
# children could not - and every request failed in a worker, once per request,
# in a child whose errors only reach a log while the port sat there listening.
#
# Resolved now by the one process that can, and the workers get a path. What
# neither the refusal nor anything else says is what it was given: a message
# that quotes the value teaches its reader how boards are referred to here.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;
use Plack::Runner ();

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'served' );

# A resolver, as the CLI builds one from the dashboard's registry.
my $tira = Tira->new(
    clock         => sub {'2026-08-15T19:00:00Z'},
    path_resolver => sub { return $_[0] eq 'hidden-board' ? $root : undef },
);
$tira->project_new(
    name => 'Served', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
);

my %providers = (
    render => sub {'<html></html>'},
    data   => sub {'{}'},
    Tira::CLI::browser_providers( tira => $tira, project => $root ),
);

# --- a board referred to without its path ----------------------------------
{
    # Compared as paths rather than as strings. Resolution goes through
    # abs_path, which on Windows answers in forward slashes while File::Spec
    # builds the expected value in backslashes - the same directory spelled two
    # ways, and Windows accepts both. Asserting the string made this fail on the
    # platform gate for a difference that is not a difference. TKT-222.
    my $same = sub { my ($path) = @_; $path =~ s{\\}{/}g; return $path };
    is( $same->( $tira->discover_project( project => 'hidden-board' ) ),
        $same->($root),
        'a board can be reached without naming where it is' );

    my $bare = Tira->new( clock => sub {'2026-08-15T19:00:00Z'} );
    my $unresolved = !eval { $bare->discover_project( project => 'hidden-board' ); 1 };

    # Asserted on $@ before anything else runs, because the next call clears it
    # - and asserted at all because a refusal nobody reads is indistinguishable
    # from a failure for some other reason entirely.
    like( $@, qr/resolve/i, 'it fails for want of a resolver, not for some other reason' );
    ok( $unresolved,
        'so a board reached this way needs something a worker has not got' );
}

# --- what the workers are handed -------------------------------------------
#
# Plack::Runner is loaded above and stubbed here, so nothing binds a port and
# the environment serve() prepared is readable where the workers would start.
{
    my %given;
    {
        no warnings 'redefine';
        local *Plack::Runner::run = sub { $given{root} = $ENV{TIRA_DASHBOARD_ROOT}; 1 };
        local *Plack::Runner::parse_options = sub {1};
        Tira::DashboardWeb->serve(
            project => $root, host => '127.0.0.1', port => 15099, %providers );
    }

    ok( defined $given{root}, 'the workers are told which board to serve' );
    ok( File::Spec->file_name_is_absolute( $given{root} // '' ),
        'as something they can open without resolving anything themselves' );
}

# --- and a reference that reached the workers unresolved --------------------
{
    my $bound = 0;
    my $refused;
    {
        no warnings 'redefine';
        local *Plack::Runner::run = sub { $bound++; 1 };
        local *Plack::Runner::parse_options = sub {1};
        $refused = !eval {
            Tira::DashboardWeb->serve(
                project => 'hidden-board', host => '127.0.0.1', port => 15099, %providers );
            1;
        };
    }

    my $said = $@;

    ok( $refused, 'serving is refused rather than started for a board left unresolved' );
    is( $bound, 0, 'and no worker is started to find that out for itself' );

    # The subject is established before it is denied. An unlike() against an
    # empty string passes without proving anything, which is the whole of what
    # t/147 exists to catch - and it caught this one.
    # non-empty is the whole claim: a precondition for the denial below, which
    # would otherwise pass against an empty string and prove nothing.
    like( $said, qr/\S/, 'and it says something rather than failing silently' );
    unlike( $said, qr/hidden-board/,
        'while not repeating what it was given, which would teach the reader how boards are referred to here' );
}

done_testing;

__END__

=head1 NAME

211-a-board-named-not-pathed.t - resolved before the workers, not by them

=head1 DESCRIPTION

A board may be referred to without its path, deliberately, so the agent working
a project never learns where it sits. C<discover_project> resolves such a
reference through a resolver the CLI installs.

C<dashboard.psgi> builds a plain Tira object, which has none, and C<serve()>
passed its argument through untouched - so every request failed inside a worker
while the port sat listening. The board is resolved by the process that can, and
the workers are handed something they can open.

Nothing in the refusal repeats the value it was given.

=cut
