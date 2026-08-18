#!/usr/bin/env perl
# A routine read does not hand back the credentials it stores.
#
# tira.project.show returned the parsed .tira/project.yml as it stood - people
# and all - and person_list is built on it:
#
#   sub person_list {
#       my ( $self, %args ) = @_;
#       return $self->project_show(%args)->{people};
#   }
#
# So two unprivileged reads emitted every account's algorithm, salt, iteration
# count and hash: the complete offline-cracking kit, in the default output that
# agents read and that lands in transcripts, logs, and anything pasted when
# asking for help with a board.
#
# Found while enumerating for TKT-386 - sweeping read commands for a map nested
# inside a list element, because that is the shape the TOON encoder mangles.
# people[].password is that shape. The rendering defect is why I was looking; the
# exposure is worse and is this card.
#
# The reason it survived is the reason this test is written the way it is: the
# suite asserted what commands RETURN, never what they REVEAL. So the assertions
# below are about absence, and absence is the thing a test can pass by accident -
# hence the last block, which proves the check can fail.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-18T15:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Secret', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'SCS', epic_prefix => 'SCE', ticket_prefix => 'SCT',
);

$tira->person_add( project => $root, id => 'michael', name => 'Michael' );
$tira->login_register( project => $root, id => 'michael', password => 'correct horse battery' );

# The subject has to be established before absence means anything. A password
# that was never stored is not a password that was withheld, and a test that
# cannot tell those apart passes hardest when the feature is missing entirely.

my @SECRETS = qw(password hash salt algorithm iterations);

{
    my ( undef, $stored ) = $tira->_project_data($root);
    my ($person) = grep { $_->{id} eq 'michael' } @{ $stored->{people} };
    is( ref $person->{password}, 'HASH', 'the password is stored, so withholding it is a real act' );
    ok( defined $person->{password}{hash} && $person->{password}{hash} ne '',
        'and there is a hash on disk to give away' );
}

# --- what the two commands hand back ----------------------------------------------------

sub secrets_in {
    my ($data) = @_;
    my @found;
    my $walk;
    $walk = sub {
        my ( $node, $path ) = @_;
        if ( ref $node eq 'HASH' ) {
            for my $key ( sort keys %{$node} ) {
                push @found, "$path.$key" if grep { $_ eq $key } @SECRETS;
                $walk->( $node->{$key}, "$path.$key" );
            }
        }
        elsif ( ref $node eq 'ARRAY' ) {
            $walk->( $node->[$_], "$path\[$_]" ) for 0 .. $#{$node};
        }
        return;
    };
    $walk->( $data, '' );
    return \@found;
}

{
    my $shown = $tira->project_show( project => $root );
    is_deeply( secrets_in($shown), [], 'project_show gives away nothing of the password' )
      or diag( 'found: ' . join ', ', @{ secrets_in($shown) } );

    my $people = $tira->person_list( project => $root );
    is_deeply( secrets_in($people), [], 'and neither does person_list, which is built on it' )
      or diag( 'found: ' . join ', ', @{ secrets_in($people) } );
}

# --- every surface that hands back a person, not the two I started with ---------------
#
# The first fix deleted the field in project_show, which covered it and
# person_list - and left three. person_update, person_activate and
# person_deactivate each return the record they just wrote, straight out of
# _project_data, so all three printed the hash on success. They are the commands
# a person runs ABOUT SOMEBODY ELSE'S account, which makes them the worse three
# of the five.
#
# Driven off the list rather than the pair, because the reason the leak survived
# is that nothing asserted the general property - only what each command returns.

{
    my %surface = (
        project_show      => sub { $tira->project_show( project => $root ) },
        person_list       => sub { $tira->person_list( project => $root ) },
        person_update     => sub { $tira->person_update( project => $root, id => 'michael', name => 'Michael' ) },
        person_deactivate => sub { $tira->person_deactivate( project => $root, id => 'michael' ) },
        person_activate   => sub { $tira->person_activate( project => $root, id => 'michael' ) },
    );

    for my $name ( sort keys %surface ) {
        my $found = secrets_in( $surface{$name}->() );
        is_deeply( $found, [], "$name hands back nothing of the password" )
          or diag( "$name leaked: " . join ', ', @{$found} );
    }

    # Sorted order runs deactivate after activate, which would leave the person
    # inactive and make every login assertion below fail for a reason that has
    # nothing to do with the redaction. Put back deliberately rather than by
    # ordering the hash, so the next surface added cannot reintroduce it.
    $tira->person_activate( project => $root, id => 'michael' );
}

# --- and the answer is otherwise unchanged ------------------------------------------------
#
# A redaction that took the people with it would break every reader that asks
# project.show who is on this board, which is what it is mostly asked.

{
    my $shown = $tira->project_show( project => $root );
    is( $shown->{name}, 'Secret', 'the project still says what it is' );

    my ($person) = grep { $_->{id} eq 'michael' } @{ $shown->{people} };
    ok( $person, 'the person is still listed' );
    is( $person->{name}, 'Michael', 'with their name' );
    ok( exists $person->{active}, 'and whether they are active' );
}

# --- login still works, which is the half that would be worse to break ----------------------

{
    ok( $tira->login_verify( project => $root, id => 'michael', password => 'correct horse battery' ),
        'the right password still authenticates after the redaction' );
    ok( !$tira->login_verify( project => $root, id => 'michael', password => 'wrong' ),
        'and the wrong one still does not' );
}

# --- the store itself is untouched -----------------------------------------------------------
#
# Withholding on the way out, not deleting on the way through. If project_show
# mutated what it loaded, the first read would destroy the credential.

{
    $tira->project_show( project => $root );
    my ( undef, $stored ) = $tira->_project_data($root);
    my ($person) = grep { $_->{id} eq 'michael' } @{ $stored->{people} };
    is( ref $person->{password}, 'HASH', 'the stored password survives a read' );
    ok( $tira->login_verify( project => $root, id => 'michael', password => 'correct horse battery' ),
        'and still authenticates afterwards' );
}

# --- proved by putting the leak back -----------------------------------------------------
#
# Absence passes by accident more easily than any other assertion - a command
# that returned nothing at all would satisfy every check above. So the detector
# is pointed at a structure that definitely contains the secret, and must find it.

{
    my ( undef, $raw ) = $tira->_project_data($root);
    my $found = secrets_in($raw);
    ok( scalar @{$found}, 'the detector finds the password when it is there' );
    ok( ( grep { /password\.hash\z/ } @{$found} ), 'and names the hash by its path' )
      or diag( 'found: ' . join ', ', @{$found} );
}

done_testing;

__END__

=head1 NAME

271-a-read-that-gives-away-a-password.t - TKT-388

=head1 DESCRIPTION

C<project_show> returned the parsed project file as it stood, and C<person_list>
is built on it, so two routine reads emitted every account's password hash, salt
and KDF parameters. Both now withhold it. Authentication reads the person through
C<_project_data> rather than C<project_show>, so the redaction cannot break the
login - and this test proves that rather than assuming it.

=cut
