#!/usr/bin/env perl
# TKT-949. His report, twice: "I also asked this bridge section never work."
# The panel says "Nothing on the bridge yet. Police announces here when it
# runs." while police announces continuously.
#
# TWO DEFECTS, both confirmed by measurement before this file was written.
#
# 1. THE PANEL READS WHATEVER PROJECT THE SERVER PROCESS DISCOVERS, not the
#    board it is serving. GET /bridge calls $tira->discover_project() and
#    derives the police store from it, and _police_store slugs the project
#    PATH into ~/.tira-police/<slug>. discover_project searches UPWARD from
#    where it starts. The dashboard serving this board runs with a working
#    directory that is an ANCESTOR of the board root - the board is below it -
#    so searching up can never reach it. Measured: 269 store directories exist
#    on this machine, 180 with an enforcement.json, and running the handler's
#    own logic from the project returns 13037 entries while the panel shows
#    none.
#
# 2. IT CANNOT SAY THAT IT FAILED. The whole read sits in eval {...} // [],
#    deliberately, so a cosmetic panel cannot take the page down - a rule worth
#    keeping. The cost nobody paid is that a board it cannot resolve, a store
#    it cannot read, and a genuinely quiet bridge all render as one sentence.
#    Had it ever been able to say "I could not read this", his report would
#    have been a different sentence and this would have been found the day it
#    shipped.
#
# THE SEAM. The board's identity is already a package variable for exactly this
# kind of reason: TKT-946 added $PORT so the cookie and the session binding
# could agree on which board this is. The same shape works here - the served
# root, set once at startup, used when set, and discover_project only as the
# fallback a library-context board still needs. That makes it testable by
# localising a variable, the way t/568 tests $PORT, instead of by starting a
# server from a chosen directory.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;
use Tira::CLI::Police;
use Tira::DashboardWeb ();

# Called through a guard so a missing seam reports as failed assertions rather
# than aborting the file on an undefined subroutine - which would leave the
# source-level assertions below unrun, and those are the ones that say whether
# the red is about the right thing.
sub payload {
    return undef if !Tira::DashboardWeb->can('_bridge_payload');
    my $out = eval { Tira::DashboardWeb::_bridge_payload(@_) };
    return $out;
}

sub board {
    my ($name) = @_;
    my $tmp  = tempdir( CLEANUP => 1 );
    my $tira = Tira->new( clock => sub {'2026-09-06T00:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, $name );
    $tira->project_new(
        name => $name, dir => $root, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'BWS', epic_prefix => 'BWE', ticket_prefix => 'BWT',
    );
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ) );
}

# --- the bridge reads the board it is told to, not the one it discovers -----
#
# The half that clears his symptom. Two boards exist; the read is pointed at
# one of them explicitly and must return that one's announcements.

{
    my ( $tira, $root, $store ) = board('served');
    my $payload = payload( tira => $tira, root => $root, store => $store );

    ok( ref $payload eq 'HASH', 'the bridge read answers with a payload rather than a bare list' );
    ok( $payload && $payload->{ok}, 'a store it can read is reported as a successful read' );
    is( ref( $payload && $payload->{entries} ), 'ARRAY', 'and the entries come back as a list' );
}

# --- a read it could not make is not an empty bridge ------------------------
#
# The half that would have surfaced defect 1 on the day it shipped. A failure
# and a quiet board must not render as the same sentence.

{
    my ( $tira, $root, $store ) = board('unreadable');

    my $payload = payload( tira => $tira, root => undef, store => undef );

    ok( ref $payload eq 'HASH', 'a failed read still answers with a payload' );
    ok( $payload && !$payload->{ok},
        'a read it could not make is reported as a FAILURE, not as an empty bridge - '
          . 'which is the distinction the panel has never been able to draw' );
    # non-empty is the whole claim: an absent error string would pass a bare
    # defined() check while telling the reader nothing.
    like( ( $payload && $payload->{error} ) // '', qr/\S/,
        'and it carries a reason, so the panel can say what went wrong rather than "nothing yet"' );
}

# --- a genuinely quiet board is still quiet --------------------------------
#
# The direction a careless fix breaks: turning silence into an error would be
# worse than the bug, because most boards are quiet most of the time.

{
    my ( $tira, $root, $store ) = board('quiet');

    my $payload = payload( tira => $tira, root => $root, store => $store );

    ok( $payload && $payload->{ok}, 'a board that simply has nothing to say is still a successful read' );
    is( scalar @{ ( $payload && $payload->{entries} ) || [] }, 0, 'with no entries, which is what the empty-state message is for' );
}

# --- the served root is used when it is known ------------------------------
#
# The identity, held the way TKT-946 holds the port: set once at startup, used
# when set, with discover_project as the fallback a library-context board needs.

{
    my $engine = Suite::engine_source();
    # non-empty is the whole claim: the checks below would pass on an
    # unreadable file's emptiness alone otherwise.
    like( $engine, qr/\S/, 'the engine source is there to be read' );

    like( $engine, qr/our\s+\$BOARD_ROOT/,
        'the served board root is a package variable, so the bridge can be told which board it is '
          . 'serving instead of guessing from the process working directory' );

    my ($route) = $engine =~ /(get \s* '\/bridge' \s* => .*?\n \};)/xs;
    ok( defined $route, 'the bridge route was found' );
    like( $route, qr/_bridge_payload/,
        'and the route reads through the payload seam, so the failure case has one home' );
}

# --- the reason is written down where it will be read ----------------------
#
# Without this the next reader sees discover_project replaced by a variable,
# thinks it indirection for its own sake, and puts it back - reintroducing his
# bug. The same guard t/568 puts on the port in the cookie name.

{
    my $engine = Suite::engine_source();
    # non-empty is the whole claim: the check below needs a real subject.
    like( $engine, qr/\S/, 'the engine source is there to be read' );
    like( $engine, qr/searches upward|ancestor of the board root/i,
        'the code records WHY discover_project cannot be trusted here - it searches upward, and the '
          . 'dashboard runs above the board it serves' );
}

done_testing();

__END__

=head1 NAME

571-a-bridge-that-reads-the-wrong-board.t - the Bridge panel reads the board it serves, and can say when it could not

=head1 DESCRIPTION

TKT-949. C<GET /bridge> derived its police store from
C<discover_project()>, which searches upward from the server process's working
directory - and the dashboard runs above the board it serves, so it could never
reach it. The whole read then sat in C<eval {...} // []>, so a board it could
not resolve, a store it could not read, and a genuinely quiet bridge all
rendered as "Nothing on the bridge yet".

The read now goes through C<_bridge_payload>, which reports success with
entries or failure with a reason, and the served board's root is held in a
package variable the way TKT-946 holds the port. A failing read still cannot
take the page down.

=cut
