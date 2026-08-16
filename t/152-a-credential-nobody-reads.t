#!/usr/bin/env perl
# A credential a command never looks at cannot be typed at it.
#
# --token was parsed, accepted on the four login commands, and read by nothing.
# The only place the option was ever looked at was the guard refusing it
# everywhere else, and that guard's message - "A token belongs to the login
# commands" - sent the caller to the commands where it did nothing.
#
# Proved by running, before a line was changed:
#
#   login.status --token anything      exit 0, lists sessions, token ignored
#   login.check --id michael --token anything
#                                      exit 0, {"ok":false}
#   login.logout --token anything      refused, but for the missing --id
#
# The middle one is the worst answer of the three. A caller checking a token
# gets a definite no about something the command never looked at, and a definite
# no is exactly what a credential check is trusted to mean.
#
# It is the base field of TKT-143 again, one layer up and on a credential path.
# Nothing read it, so removing it changes no behaviour; ending one named session
# by token is a plausible thing to want and would be a new feature, not this.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-14T08:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Credentials', dir => $root, members => ['michael'],
    columns => ['backlog, done'],
    sow_prefix => 'CRS', epic_prefix => 'CRE', ticket_prefix => 'CRT',
);

sub run {
    my (@argv) = @_;
    my $command = shift @argv;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => $command, tira => $tira,
            argv => [ @argv ] ) };
    };
    return ( $status, $out, $err );
}

is( ( run( 'login.register', '--id', 'michael', '--password', 'a-long-enough-password' ) )[0],
    0, 'somebody is registered to sign in' );

# --- typed at the commands that accepted it ------------------------------------
#
# All four, because it was accepted on all four and fixing only the one that
# reads worst would leave the other three accepting it.

for my $command (qw(login.status login.check login.logout login.register)) {
    my ( $status, undef, $err ) = run( $command, '--token', 'completely-made-up' );
    isnt( $status, 0, "$command refuses a token rather than accepting one it never reads" );
    like( $err, qr/Unknown option|Invalid command-line/i,
        "and $command refuses it as an option that does not exist" );
}

# --- and the message that used to send them there ---------------------------------
#
# Once nothing accepts a token, a refusal telling somebody it belongs to the
# login commands is a document describing something that does not ship, written
# into a die string.

{
    my ( $status, undef, $err ) = run( 'record.list', '--type', 'ticket', '--token', 'x' );
    isnt( $status, 0, 'a token is still refused everywhere else' );
    unlike( $err, qr/belongs to the login commands/,
        'and no longer sent anywhere, because there is nowhere it belongs' );
}

# --- while signing in still works ---------------------------------------------------
#
# The risk in deleting an option is deleting one that mattered. These are the
# four commands it was accepted on, doing their jobs.

{
    my ( $status, $out ) = run( 'login.check', '--id', 'michael', '--password', 'a-long-enough-password' );
    is( $status, 0, 'a password can still be checked' );
    like( $out, qr/ok:\s*1/, 'and the right one is accepted' );
}
{
    my ( undef, $out ) = run( 'login.check', '--id', 'michael', '--password', 'the-wrong-one-entirely' );
    like( $out, qr/ok:\s*0/, 'while the wrong one is not' );
}
is( ( run('login.status') )[0], 0, 'sessions can still be listed' );
is( ( run( 'login.logout', '--all' ) )[0], 0, 'and ended' );

# --- nothing in the engine lost a token either ----------------------------------------
#
# The sessions themselves still have tokens; what went is the ability to type
# one at a command that would not look at it. The browser flow passes its token
# in the request body and never through this parser.

my $token = $tira->login_start( project => $root, id => 'michael',
    password => 'a-long-enough-password' );
ok( $token, 'signing in still yields a token' );
is( scalar @{ $tira->session_list( project => $root ) }, 1, 'and a session to go with it' );
ok( $tira->session_end( project => $root, token => ref $token ? $token->{token} : $token ),
    'and that token still ends its own session, which is where a token is really used' );

done_testing;

__END__

=head1 NAME

152-a-credential-nobody-reads.t - a credential a command never looks at cannot be typed at it

=head1 DESCRIPTION

C<--token> was accepted on the four login commands and read by nothing. The only
place it was looked at was the guard refusing it elsewhere, whose message sent
the caller to the commands where it did nothing.

C<login.check --token> was the worst of it: exit zero and a definite C<false>
about a credential the command never examined. The option is gone, so typing it
is refused as unknown wherever it appears, and the message pointing at the login
commands went with it. Sessions still have tokens, and a token still ends its own
session - what went is the ability to type one at a command that would not look
at it.

=cut
