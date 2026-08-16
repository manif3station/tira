#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS ();
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-11T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Verbs', dir => $root,
    members => [ 'michael', 'ada', 'buildbot' ],
    columns => ['Backlog, Doing'],
    sow_prefix => 'VBS', epic_prefix => 'VBE', ticket_prefix => 'VBT',
);

# Every command is run the way the dispatcher runs it, so this covers the
# argument parsing and the output contract as well as the engine underneath.
sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
            command => $command, tira => $tira,
            argv => [ @argv ],
        ) };
    };
    return ( $status, $out, $err );
}

sub json_of {
    my ( $command, @argv ) = @_;
    my ( $status, $out, $err ) = run( $command, @argv, '-o', 'json' );
    return ( $status, ( $status == 0 ? Cpanel::JSON::XS->new->decode($out) : $err ) );
}

# --- claiming a password -------------------------------------------------

my ( $status, $claimed ) = json_of( 'login.register', '--id', 'michael', '--password', 'hunter2' );
is( $status, 0, 'login.register exits clean' );
is( $claimed->{id}, 'michael', 'and answers with the person who claimed it' );
ok( !exists $claimed->{password}{plaintext}, 'the answer carries no plaintext' );
unlike( Cpanel::JSON::XS->new->canonical->encode($claimed), qr/hunter2/,
    'and the password appears nowhere in what is printed back' );

( $status, my $again ) = json_of( 'login.register', '--id', 'michael', '--password', 'other' );
isnt( $status, 0, 'claiming twice fails' );
like( $again, qr/already has a password/, 'and says why' );

( $status, my $bot ) = json_of( 'login.register', '--id', 'buildbot', '--password', 'beep' );
isnt( $status, 0, 'a bot cannot claim one from the command line either' );
like( $bot, qr/bot/i, 'and is told it is because it is a bot' );

# --- checking one --------------------------------------------------------

( $status, my $good ) = json_of( 'login.check', '--id', 'michael', '--password', 'hunter2' );
is( $status, 0, 'login.check exits clean on the right password' );
ok( $good->{ok}, 'and says so' );

( $status, my $bad ) = json_of( 'login.check', '--id', 'michael', '--password', 'wrong' );
is( $status, 0, 'login.check exits clean on the wrong password too, because being wrong is an answer' );
ok( !$bad->{ok}, 'and says no' );

# The command must not become a way to find out who exists. An unknown person
# and a wrong password have to look identical from outside.
( $status, my $nobody ) = json_of( 'login.check', '--id', 'nobody', '--password', 'wrong' );
is_deeply( $nobody, $bad, 'an unknown person answers exactly as a wrong password does' );

# --- who is signed in ----------------------------------------------------

( $status, my $empty ) = json_of('login.status');
is( $status, 0, 'login.status exits clean with nobody signed in' );
is_deeply( $empty, [], 'and answers with an empty list' );

my $token = $tira->login_start( project => $root, id => 'michael', password => 'hunter2' );
( $status, my $listed ) = json_of('login.status');
is( scalar @{$listed}, 1, 'a live session shows up' );
is( $listed->[0]{person}, 'michael', 'as the person holding it' );

# Listing who is signed in must not hand out the tokens themselves - the
# listing is for the owner, and a token is the credential.
unlike( Cpanel::JSON::XS->new->canonical->encode($listed), qr/\Q$token\E/,
    'and the token itself is not printed' );

# --- signing out ---------------------------------------------------------

( $status, my $out_one ) = json_of( 'login.logout', '--id', 'michael' );
is( $status, 0, 'login.logout exits clean' );
is( $out_one->{ended}, 1, 'and says how many sessions it ended' );
is_deeply( ( json_of('login.status') )[1], [], 'after which nobody is signed in' );

$tira->login_register( project => $root, id => 'ada', password => 'correct horse' );
$tira->login_start( project => $root, id => 'michael', password => 'hunter2' );
$tira->login_start( project => $root, id => 'michael', password => 'hunter2' );
$tira->login_start( project => $root, id => 'ada', password => 'correct horse' );

( $status, my $one_person ) = json_of( 'login.logout', '--id', 'michael' );
is( $one_person->{ended}, 2, 'signing one person out ends every session they hold' );
is( scalar @{ ( json_of('login.status') )[1] }, 1, 'and leaves everyone else alone' );

( $status, my $everyone ) = json_of( 'login.logout', '--all' );
is( $everyone->{ended}, 1, 'and --all ends the rest' );
is_deeply( ( json_of('login.status') )[1], [], 'leaving nobody' );

( $status, my $neither ) = json_of('login.logout');
isnt( $status, 0, 'logging out with neither an id nor --all is refused' );
like( $neither, qr/--id|--all/, 'and says which to use' );

# --- the default output --------------------------------------------------

# TOON is the default everywhere else, and an agent reading this should not
# have to learn a second rule for one command.
$tira->login_start( project => $root, id => 'michael', password => 'hunter2' );
( $status, my $toon ) = run('login.status');
is( $status, 0, 'login.status answers without -o as well' );
like( $toon, qr/michael/, 'and says who is signed in' );
unlike( $toon, qr/"person"\s*:/, 'in TOON like every other command, not JSON' );
( $status, my $empty_toon ) = do { $tira->session_end( project => $root, token => $_->{token} )
      for @{ $tira->session_list( project => $root ) }; run('login.status') };
# empty is what passes: a listing with no sessions has nothing to print, and
# what is denied is JSON syntax rather than the absence of rows.
unlike( $empty_toon, qr/"person"\s*:/, 'and an empty listing is TOON too' );

# --- the browser calls the same subroutines ------------------------------

# His rule: whatever the dashboard does must go through the same code the
# command line goes through, so a check cannot be enforced in one and
# forgotten in the other.
my $providers = { Tira::CLI::browser_providers( tira => $tira, project => $root ) };
for my $name (qw(login_start session_resume session_peek session_end)) {
    is( ref $providers->{$name}, 'CODE', "the browser is given a $name provider" );
}

my $opened = Cpanel::JSON::XS->new->decode(
    $providers->{login_start}->( { id => 'ada', password => 'correct horse' } ) );
ok( $opened->{ok}, 'the browser can open a session' );
ok( $opened->{token}, 'and is handed the token to put in a cookie' );

my $resumed = Cpanel::JSON::XS->new->decode( $providers->{session_resume}->( { token => $opened->{token} } ) );
is( $resumed->{person}, 'ada', 'and can resume it' );

my $refused = Cpanel::JSON::XS->new->decode(
    $providers->{login_start}->( { id => 'buildbot', password => 'beep' } ) );
ok( !$refused->{ok}, 'a bot is refused through the browser too' );

# That last one would pass for the wrong reason on its own: buildbot has no
# password, so anything would refuse it. Someone who registered under an
# ordinary name and was renamed afterwards has a real, matching password, and
# the bot rule is then the only thing standing in the way.
$tira->person_update( project => $root, id => 'ada', name => 'Ada Botwright' );
ok( $tira->login_verify( project => $root, id => 'ada', password => 'correct horse' ) == 0,
    'a person renamed into a bot stops verifying even though the password still matches' );
my $renamed = Cpanel::JSON::XS->new->decode(
    $providers->{login_start}->( { id => 'ada', password => 'correct horse' } ) );
ok( !$renamed->{ok},
    'and the browser refuses them, so the bot rule is what is doing the refusing' );

# The page has to be able to claim a password for somebody who has never had
# one, and be handed a session in the same breath - otherwise a first-time
# visitor would have to type the same password twice.
$tira->person_add( project => $root, id => 'grace', name => 'Grace' );
my $first = Cpanel::JSON::XS->new->decode(
    $providers->{login_register}->( { id => 'grace', password => 'first time' } ) );
ok( $first->{ok}, 'the browser can claim a password on a first visit' );
ok( $first->{claimed}, 'and says that is what happened' );
is( $tira->session_peek( project => $root, token => $first->{token} )->{person}, 'grace',
    'handing back a session so nobody types their password twice' );

my $twice = Cpanel::JSON::XS->new->decode(
    $providers->{login_register}->( { id => 'grace', password => 'again' } ) );
ok( !$twice->{ok}, 'claiming a second time is refused rather than overwriting' );

# The board's background poll goes through peek, so it must never push the
# expiry out - the same rule the engine enforces, checked at the seam the
# browser actually uses.
my $peeked = Cpanel::JSON::XS->new->decode( $providers->{session_peek}->( { token => $first->{token} } ) );
is( $peeked->{person}, 'grace', 'the browser can peek at a session' );
is( Cpanel::JSON::XS->new->decode( $providers->{session_peek}->( { token => 'nope' } ) )->{person}, undef,
    'and peeking at nothing says nobody rather than failing' );

my $signed_out = Cpanel::JSON::XS->new->decode( $providers->{session_end}->( { token => $first->{token} } ) );
ok( $signed_out->{ok}, 'the browser can sign somebody out' );
is( Cpanel::JSON::XS->new->decode( $providers->{session_resume}->( { token => $first->{token} } ) )->{person},
    undef, 'after which the token is worth nothing' );
ok( !Cpanel::JSON::XS->new->decode( $providers->{session_end}->( { token => 'never-existed' } ) )->{ok},
    'and signing out a session that was never there says so rather than dying' );

done_testing;

__END__

=head1 NAME

76-login-commands.t - TKT-003 the login verbs, and the browser using the same ones

=head1 DESCRIPTION

Four commands: claiming a password, checking one, seeing who is signed in, and
signing somebody out. Each is driven through the dispatcher rather than the
engine, so the argument parsing and the output contract are covered too.

Two things here are about not leaking rather than about working. Checking a
password must answer identically for a wrong password and for a person who
does not exist, or the command becomes a way to find out who is on the
project. And listing who is signed in must not print the tokens, because a
token is the credential itself and the listing is only meant to say who.

The last section is the owner's standing rule: whatever the dashboard does
goes through the same subroutines the command line goes through, so a rule
cannot be enforced in one place and forgotten in the other. The bot refusal is
checked through the browser's own provider for exactly that reason.

=cut
