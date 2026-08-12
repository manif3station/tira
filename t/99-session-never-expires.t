#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $now = '2026-08-12T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
sub at { $now = $_[0] }

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Open', dir => $root, members => ['michael'],
    columns => ['backlog, doing'],
    sow_prefix => 'OPS', epic_prefix => 'OPE', ticket_prefix => 'OPT',
);
$tira->login_register( project => $root, id => 'michael', password => 'hunter2' );

# --- as it is, and stays by default ---------------------------------------

# Ten minutes of idleness ends a session, so a tab left open overnight on a
# shared machine does not stay signed in. That is the default and this card
# does not change it.
{
    my $token = $tira->login_start( project => $root, id => 'michael', password => 'hunter2' );
    at('2026-08-12T09:09:00Z');
    ok( $tira->session_peek( project => $root, token => $token ), 'a session is alive before the timeout' );
    at('2026-08-12T09:11:00Z');
    ok( !$tira->session_peek( project => $root, token => $token ), 'and gone after it, exactly as today' );
}

# --- and when the owner says otherwise ------------------------------------

# His board lives on his phone and he reads it instead of asking for progress.
# A board that is honest for ten minutes and silent afterwards is no use for
# that, so he can say the session outlives idleness - and it is his decision,
# taken deliberately, not the board's.
{
    local $Tira::SESSION_NEVER_EXPIRES = 1;
    my $token = $tira->login_start( project => $root, id => 'michael', password => 'hunter2' );

    at('2026-08-12T21:00:00Z');
    ok( $tira->session_peek( project => $root, token => $token ),
        'twelve hours later the board still knows who is looking at it' );

    at('2026-08-15T09:00:00Z');
    ok( $tira->session_resume( project => $root, token => $token ),
        'and three days later, because never means never' );
}

# --- ending one still ends it ---------------------------------------------

# Never expiring is not the same as never ending: signing out must still work,
# or the option becomes a session nobody can get rid of.
{
    local $Tira::SESSION_NEVER_EXPIRES = 1;
    my $token = $tira->login_start( project => $root, id => 'michael', password => 'hunter2' );
    ok( $tira->session_end( project => $root, token => $token ), 'signing out ends it' );
    ok( !$tira->session_peek( project => $root, token => $token ), 'and it is gone' );
}

# --- the option, and the board saying so ----------------------------------

# A board serving sessions that never expire is a different thing from one that
# does, and somebody looking at it should be able to tell.
{
    my @calls;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run(
            command => 'dashboard.ticket', tira => $tira,
            argv => [ '--project', $root, '-o', 'browser', '--no-session-expire' ],
            browser_server => sub { push @calls, {@_}; return 1 },
        );
    }
    ok( scalar @calls, 'the option is accepted by the browser dashboard' );
    ok( $Tira::SESSION_NEVER_EXPIRES,
        'and it is what makes sessions outlive idleness, rather than a flag nothing reads' );

    like( $err . $out, qr/never expire|do not expire/i,
        'and the board says so where somebody starting it can see' );
}

done_testing;

__END__

=head1 NAME

99-session-never-expires.t - a board left open that stays open

=head1 DESCRIPTION

Michael reads the board instead of asking for progress, from a phone, all day.
A session that ends after ten minutes of idleness means the page he glances at
is signed out most of the time, and the sign-in stands between him and the
thing he opened the board to see.

The expiry exists for a reason - a tab left open overnight should not keep
itself signed in on a shared machine - so this is a decision he makes rather
than a default that changes. Without the option nothing here is different.

Never expiring is not never ending: signing out still ends a session, or the
option would create one nobody could get rid of.

=cut
