#!/usr/bin/env perl
# TKT-686. login_verify checks algorithm, salt and hash against a stored
# password record, and passes the fourth field - iterations - straight into
# _password_derive, which iterates with `for ( 2 .. $iterations )`. Measured:
# undef, 0 and 1 all produce the same single-round digest, because
# `2 .. undef` and `2 .. 0` are both empty ranges. A record still claiming
# pbkdf2-hmac-sha256 can be verified as a bare HMAC, silently, and a record
# with an absurdly large stored value makes sign-in hang.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-01T15:00:00+0100' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Guarded', dir => $root, members => ['michael'],
    columns => ['backlog, doing'],
    sow_prefix => 'GFS', epic_prefix => 'GFE', ticket_prefix => 'GFT',
);

sub project_data {
    my ( undef, $data ) = $tira->_project_data($root);
    return $data;
}

sub write_data {
    my ($data) = @_;
    my $path = File::Spec->catfile( $root, '.tira', 'project.yml' );
    $tira->_write_yaml( $path, $data );
    return 1;
}

sub set_iterations {
    my ($value) = @_;
    my $data = project_data();
    my ($person) = grep { $_->{id} eq 'michael' } @{ $data->{people} };
    if ( defined $value ) {
        $person->{password}{iterations} = $value;
    }
    else {
        delete $person->{password}{iterations};
    }
    write_data($data);
    return 1;
}

$tira->login_register( project => $root, id => 'michael', password => 'hunter2' );
my $stored_hash = project_data()->{people}[0]{password}{hash};

# --- the fix: undef/0/1/below-floor are all refused, not silently accepted ---

for my $bad_value ( undef, 0, 1, 100 ) {
    set_iterations($bad_value);
    ok( !$tira->login_verify( project => $root, id => 'michael', password => 'hunter2' ),
        'a stored iterations of ' . ( $bad_value // 'undef' ) . ' is refused rather than verified with one round' );
}

# --- an absurdly large value is refused before any hashing is attempted -----

set_iterations(5_000_000);
my $before = time;
ok( !$tira->login_verify( project => $root, id => 'michael', password => 'hunter2' ),
    'an absurdly large stored iterations value is refused' );
ok( time - $before < 5,
    'and refused immediately - sign-in cannot be made to hang by an oversized stored value' );

# --- a genuine record still verifies -----------------------------------------

set_iterations($Tira::PASSWORD_ITERATIONS);
ok( $tira->login_verify( project => $root, id => 'michael', password => 'hunter2' ),
    'a record with the real write-time iteration count still verifies' );

# --- raising the write-time cost does not invalidate what was already written -----

{
    local $Tira::PASSWORD_ITERATIONS = $Tira::PASSWORD_ITERATIONS + 50_000;
    ok( $tira->login_verify( project => $root, id => 'michael', password => 'hunter2' ),
        'raising the write-time cost does not invalidate a record written at the old one' );
}

# --- _password_derive refuses to run without a real count -------------------

for my $bad_value ( undef, 0, -1 ) {
    ok( !eval { Tira::_password_derive( 'hunter2', 'ab', $bad_value ); 1 },
        '_password_derive dies rather than deriving a one-round digest for ' . ( $bad_value // 'undef' ) );
}

# --- and produces no uninitialized-value warning along the way --------------

set_iterations(undef);
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };
$tira->login_verify( project => $root, id => 'michael', password => 'hunter2' );
is_deeply( \@warnings, [], 'refusing a record with no stored iterations produces no warning' );

done_testing;

__END__

=head1 NAME

t/476-a-work-factor-nobody-checked.t - login_verify validates the one field
of a stored password record it used to trust blindly

=head1 DESCRIPTION

C<login_verify> checked algorithm, salt and hash against a stored password
record but passed C<iterations> straight into C<_password_derive>, whose
C<for ( 2 .. $iterations )> loop silently does nothing when C<$iterations> is
undef, 0, or 1 - all three produced the identical single-round digest in
place of the real write-time cost, and the undef case additionally printed
an uninitialized-value warning. A record still claiming
C<pbkdf2-hmac-sha256> could be verified as a bare HMAC, and an absurdly
large stored value made sign-in hang.

C<login_verify> now refuses a stored record whose C<iterations> is not a
positive integer at or above C<$Tira::PASSWORD_ITERATIONS_FLOOR>, and above
C<$Tira::PASSWORD_ITERATIONS_CEILING> refuses before any hashing is
attempted. C<_password_derive> dies rather than deriving a weak digest when
given no usable count. TKT-686.

=cut
