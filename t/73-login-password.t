#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-11T09:00:00Z' } );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Guarded', dir => $root,
    members => [ 'michael', 'ada', 'buildbot', 'Robotics' ],
    columns => ['Backlog, Doing'],
    sow_prefix => 'GRS', epic_prefix => 'GRE', ticket_prefix => 'GRT',
);
$tira->person_deactivate( project => $root, id => 'ada' );

sub config_text {
    my $path = File::Spec->catfile( $root, '.tira', 'project.yml' );
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub write_config {
    my ($text) = @_;
    my $path = File::Spec->catfile( $root, '.tira', 'project.yml' );
    open my $fh, '>:raw', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
    return 1;
}

sub person_named {
    my ($id) = @_;
    my ($person) = grep { $_->{id} eq $id } @{ $tira->person_list( project => $root ) };
    return $person;
}

# --- claiming ------------------------------------------------------------

my $claimed = $tira->login_register( project => $root, id => 'michael', password => 'hunter2' );
is( $claimed->{id}, 'michael', 'registering answers with the person who claimed it' );

my $stored = person_named('michael')->{password};
is( ref $stored, 'HASH', 'the claim leaves a password block on the person' );

# The whole point of a hash is that the file cannot give the password back.
# Searching the written bytes is the only check that actually proves it: a
# structural test would pass just as happily against a block that carried the
# password along in a field nobody thought to look at.
unlike( config_text(), qr/hunter2/, 'the password itself is nowhere in the project config' );

ok( defined $stored->{algorithm} && length $stored->{algorithm}, 'the block records its algorithm' );
ok( ( $stored->{iterations} // 0 ) >= 100_000, 'the block records a serious iteration count' );
ok( defined $stored->{salt} && length $stored->{salt} >= 16, 'the block records a salt' );
ok( defined $stored->{hash} && length $stored->{hash}, 'the block records a hash' );

# --- salting -------------------------------------------------------------

$tira->person_add( project => $root, id => 'grace', name => 'Grace' );
$tira->login_register( project => $root, id => 'grace', password => 'hunter2' );
isnt( person_named('grace')->{password}{salt}, $stored->{salt},
    'two people get different salts' );
isnt( person_named('grace')->{password}{hash}, $stored->{hash},
    'the same password stored twice does not produce the same hash' );

# --- refusals ------------------------------------------------------------

my %refusal = (
    'an unknown person'      => { id => 'nobody', password => 'x' },
    'an inactive person'     => { id => 'ada', password => 'x' },
    'an empty password'      => { id => 'grace', password => '' },
    'a missing password'     => { id => 'grace' },
);
for my $why ( sort keys %refusal ) {
    ok( !eval { $tira->login_register( project => $root, %{ $refusal{$why} } ); 1 },
        "registering refuses $why" );
}

ok( !eval { $tira->login_register( project => $root, id => 'michael', password => 'again' ); 1 },
    'registering refuses a person who already has a password' );
ok( $tira->login_verify( project => $root, id => 'michael', password => 'hunter2' ),
    'the refused second claim did not overwrite the first' );

# --- verifying -----------------------------------------------------------

ok( $tira->login_verify( project => $root, id => 'michael', password => 'hunter2' ),
    'the right password verifies' );
ok( !$tira->login_verify( project => $root, id => 'michael', password => 'hunter3' ),
    'the wrong password does not' );
ok( !$tira->login_verify( project => $root, id => 'grace', password => '' ),
    'an empty password never verifies' );
ok( !$tira->login_verify( project => $root, id => 'nobody', password => 'hunter2' ),
    'an unknown person never verifies' );

$tira->person_add( project => $root, id => 'newcomer', name => 'Newcomer' );
ok( !$tira->login_verify( project => $root, id => 'newcomer', password => 'anything' ),
    'a person who has never registered never verifies' );
ok( !$tira->login_verify( project => $root, id => 'ada', password => 'anything' ),
    'an inactive person never verifies' );

# --- bots ----------------------------------------------------------------

# His rule is that a name containing "bot" is a machine, and machines do not
# get to drive the board through a browser.
for my $bot (qw(buildbot Robotics)) {
    ok( !eval { $tira->login_register( project => $root, id => $bot, password => 'beep' ); 1 },
        "$bot cannot claim a password" );
    ok( !$tira->login_verify( project => $root, id => $bot, password => 'beep' ),
        "$bot cannot verify" );
}

$tira->person_add( project => $root, id => 'sandra', name => 'Sandra Botwright' );
ok( !eval { $tira->login_register( project => $root, id => 'sandra', password => 'x' ); 1 },
    'the bot rule reads the display name as well as the id' );

# A hash written by hand must not become a way past the bot rule.
{
    my $block = person_named('michael')->{password};
    my $edited = config_text();
    my $count = $edited =~ s{(\n  id: buildbot\n  name: buildbot\n)}
                            {$1 . "  password:\n"
                               . "    algorithm: $block->{algorithm}\n"
                               . "    iterations: $block->{iterations}\n"
                               . "    salt: $block->{salt}\n"
                               . "    hash: $block->{hash}\n"}e;
    is( $count, 1, 'the hand-written hash really was written into the file' );
    write_config($edited);
    is( ref person_named('buildbot')->{password}, 'HASH',
        'and the engine reads it back, so the next check is not passing by accident' );
}
ok( !$tira->login_verify( project => $root, id => 'buildbot', password => 'hunter2' ),
    'a hand-written hash does not let a bot in' );

# --- the owner's repair path ---------------------------------------------

# He said he would fix a forgotten password by deleting the block from the
# file himself. That makes hand-editing a supported path, so it is tested.
{
    my $edited = config_text();
    # Michael is the first person in the file, so the first block is his.
    my $count = $edited =~ s/^  password:\n(?:    \S.*\n)+//m;
    is( $count, 1, 'a password block really was removed from the file' );
    write_config($edited);
    ok( person_named('ada'), 'the file still parses after the hand edit' );
}
ok( !defined person_named('michael')->{password},
    'deleting the block by hand leaves the person unregistered' );
ok( !$tira->login_verify( project => $root, id => 'michael', password => 'hunter2' ),
    'the old password stops working once the block is gone' );
ok( $tira->login_register( project => $root, id => 'michael', password => 'fresh' ),
    'and the person can claim a new one' );
ok( $tira->login_verify( project => $root, id => 'michael', password => 'fresh' ),
    'which then verifies' );

# --- the parts that only differ by platform ------------------------------

# Windows has no /dev/urandom, so the fallback is the one that will actually
# run there. Pointing the reader at nothing exercises it here rather than
# discovering on the Windows lab that it was never right.
{
    local $Tira::URANDOM = File::Spec->catfile( $tmp, 'no-such-random-source' );
    my %seen;
    $seen{ Tira::_random_hex(16) }++ for 1 .. 8;
    is( scalar keys %seen, 8, 'the fallback source still gives a different answer every time' );
    is( length( ( keys %seen )[0] ), 32, 'and the right number of hex digits' );
}

{
    # A short read should be treated as a failure rather than quietly handing
    # back fewer bytes of salt than were asked for.
    local $Tira::URANDOM = File::Spec->catfile( $tmp, 'short-random-source' );
    open my $fh, '>:raw', $Tira::URANDOM or die $!;
    print {$fh} 'xy';
    close $fh;
    is( length Tira::_random_hex(16), 32, 'a source that runs out does not shorten the salt' );
}

ok( !Tira::_secret_equals( 'abc', 'abcd' ), 'two secrets of different lengths never match' );
ok( Tira::_secret_equals( 'abc', 'abc' ), 'and identical ones do' );

done_testing();

__END__

=head1 NAME

73-login-password.t - TKT-001 claiming a dashboard password, and the bot rule

=head1 DESCRIPTION

The browser dashboard is getting a login, and this covers the half of it
that has to be right on the first try: what gets written to disk.

Only a salted, iterated digest is stored, and the test proves it by
searching the written bytes for the password rather than by inspecting
the structure - a structural check would pass just as happily against a
block that carried the password along in a field nobody thought to look
at. Two people who pick the same password get different stored hashes.

The owner's rule is that a person whose id or display name contains
"bot" is a machine and cannot sign in. That is checked before the stored
hash is consulted, so a hash written into the file by hand is not a way
around it, and the test writes one by hand to prove it.

He also said he would repair a forgotten password by deleting the block
from the project file himself, which makes hand-editing a supported path
rather than an accident. So the test edits the file the way he would,
and checks the person is unregistered afterwards and can claim a new
password.

The random source is named rather than hard-coded so the fallback that
only ever runs on Windows can be exercised here. A fallback nobody has
run is a fallback nobody knows works.

=cut
