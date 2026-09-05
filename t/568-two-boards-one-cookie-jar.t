#!/usr/bin/env perl
# TKT-946. His report, TG 7125 then reproduced in 7131:
#
#   "In the same ip address of this machine there are more than 1 Tira
#    dashboard running and each of them sitting on different port number.
#    When a browser try for example 192...:7899 login and then on the same
#    browser open another tab 192....:7800 and login. Then switch back to the
#    :7899 tab that has been logged out ... and both of them can't be login at
#    the same time. I suspect is the cookie session."
#
# He was right about the cause. There is ONE cookie, named by the fixed
# constant $COOKIE = 'tira_session', and a browser's jar is keyed by HOST
# alone - RFC 6265 section 8.5 says outright that cookies do not provide
# isolation by port, and there is no attribute that changes it. So both
# boards read and write one slot and overwrite each other.
#
# WHAT HE ASKED FOR CANNOT BE DONE AS WORDED. "Tie the cookie to domain+port"
# has no cookie-level expression. Q-128 put the achievable options to him and
# he chose the server-side binding.
#
# AND BINDING ALONE WOULD NOT HAVE FIXED HIS SYMPTOM, which is why both are
# built and why he was told: with one slot, signing in at the second board
# still overwrites the first board's token, the first board is then shown a
# token bound elsewhere, and it refuses it - the tab reads as logged out just
# the same, by a different route. Two boards need two slots, and only the
# cookie NAME can give them that.
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
use Tira::DashboardWeb ();

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-05T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Two Boards', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'TBS', epic_prefix => 'TBE', ticket_prefix => 'TBT',
);
$tira->login_register( project => $root, id => 'claude', password => 'a-long-enough-password' );

# --- the cookie name distinguishes one board from another ------------------
#
# The half that actually clears his symptom. Two boards on one host must not
# share a slot, and the only thing a browser keys a cookie by that we control
# is the name.

{
    my $on_7899 = Tira::DashboardWeb::_session_cookie( 'T1', port => 7899 );
    my $on_7800 = Tira::DashboardWeb::_session_cookie( 'T2', port => 7800 );

    like( $on_7899, qr/7899/, "the cookie for the board on :7899 carries its port" );
    like( $on_7800, qr/7800/, 'and the one on :7800 carries its own' );

    my ($name_7899) = $on_7899 =~ /\A([^=]+)=/;
    my ($name_7800) = $on_7800 =~ /\A([^=]+)=/;
    isnt( $name_7899, $name_7800,
        'the two boards use DIFFERENT cookie names, so the browser keeps two slots - '
          . 'which is what "both of them can\'t be login at the same time" needs' );
}

# --- and a board with no port configured still works -----------------------
#
# Not every board is one of his. A board that cannot say which port it is on
# must still set a usable cookie rather than one named after nothing.

{
    my $bare = Tira::DashboardWeb::_session_cookie('T3');
    like( $bare, qr/\Atira_session=/,
        'with no port to hand the name is unchanged, so nothing existing breaks' );
}

# --- a token is bound to the board that issued it --------------------------
#
# His own choice on Q-128, and the half that survives a token being copied by
# hand rather than carried by a browser.

{
    my $token = $tira->login_start( project => $root, id => 'claude',
        password => 'a-long-enough-password', board => 'b-7899' );

    my $here = $tira->session_resume( project => $root, token => $token, board => 'b-7899' );
    ok( ref $here eq 'HASH' && defined $here->{person},
        'the board that issued the token accepts it' );

    my $elsewhere = $tira->session_resume( project => $root, token => $token, board => 'b-7800' );
    ok( !( ref $elsewhere eq 'HASH' && defined $elsewhere->{person} ),
        'and another board refuses it, even presented the very same token - '
          . 'which is what covers a token copied out of one board by hand' );
}

# --- a session from before this shipped is not locked out ------------------
#
# Records written before the binding existed carry no board at all. Treating
# an absent binding as a mismatch would sign everybody out on upgrade, which
# is a worse fault than the one being fixed.

{
    my $token = $tira->login_start( project => $root, id => 'claude',
        password => 'a-long-enough-password' );
    my $resumed = $tira->session_resume( project => $root, token => $token, board => 'b-7899' );
    ok( ref $resumed eq 'HASH' && defined $resumed->{person},
        'a session that names no board is accepted anywhere, so an upgrade does not sign everybody out' );
}

# --- the reason cookies cannot do this is written down --------------------
#
# Without this the next reader sees a port in a cookie name, thinks it untidy,
# and puts the constant back - reintroducing his bug. The registry in t/566
# is about exactly this kind of drift.

{
    # engine_source, not cli_source: DashboardWeb.pm lives at
    # lib/Tira/DashboardWeb.pm, and cli_source walks lib/Tira/CLI only.
    my $web = Suite::engine_source();
    # non-empty is the whole claim: the check below would pass on an
    # unreadable file's emptiness alone otherwise.
    like( $web, qr/\S/, 'the engine source is there to be read' );
    like( $web, qr/6265/,
        'the code cites the standard that makes port-scoping impossible, so nobody '
          . '"simplifies" the port back out of the cookie name' );
}

done_testing();

__END__

=head1 NAME

568-two-boards-one-cookie-jar.t - two boards on one host hold independent sessions

=head1 DESCRIPTION

TKT-946. Cookies are not isolated by port (RFC 6265 section 8.5), so two Tira
boards on one host shared a single C<tira_session> slot and overwrote each
other's tokens - his own reproduction was that signing in to the second logged
the first out, and back again, with neither able to hold a session. The cookie
name now carries the board's port, giving the browser two slots, and the
session token is additionally bound to the board that issued it and refused
elsewhere - the second being his choice on Q-128, the first being what his
reported symptom actually required. A session predating the binding names no
board and is accepted anywhere, so upgrading does not sign everybody out.

=cut
