#!/usr/bin/env perl
# tira.next returned {next, then} - a hash - when work was waiting, and a bare
# [] - an array - when nothing was: the same command answering with two
# different TYPES depending on board state. A caller written against the
# documented {next,then} shape does result->{next}, which works every time
# the board has work and raises an error the first time it goes quiet -
# precisely when a scheduled caller runs unattended and nobody is watching.
# TKT-354.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-08-23T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Quieted', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'QTS', epic_prefix => 'QTE', ticket_prefix => 'QTT',
);

sub run_next {
    my @argv = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => 'next', tira => $tira, argv => [@argv] );
    };
    return ( $status, $out . $err );
}

# --- a quiet board (no cards at all) answers with a hash, not a bare array --------

{
    my ( $status, $text ) = run_next( '-o', 'json' );
    is( $status, 0, 'next dispatches cleanly on an empty board' );
    require Cpanel::JSON::XS;
    my $result = Cpanel::JSON::XS::decode_json($text);
    is( ref $result, 'HASH', 'the answer is a hash, the same type as the busy-board answer' );
    is( $result->{next}, undef, 'next is undef - nothing is waiting' );
    is_deeply( $result->{then}, [], 'then is an empty array, not missing' );
}

# --- a caller written against the documented shape does not crash -----------------

{
    my ( $status, $text ) = run_next( '-o', 'json' );
    require Cpanel::JSON::XS;
    my $result = Cpanel::JSON::XS::decode_json($text);
    ok( exists $result->{next}, 'a caller doing result->{next} finds a key, not an error - the old shape had no such key at all on a quiet board' );
}

# --- and once a card is waiting, the shape is exactly what it always was ----------

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Now waiting', priority => 3 );

{
    my ( $status, $text ) = run_next( '-o', 'json' );
    require Cpanel::JSON::XS;
    my $result = Cpanel::JSON::XS::decode_json($text);
    is( ref $result, 'HASH', 'still a hash once work is waiting' );
    is( $result->{next}{ref}, $card->{ref}, 'next names the waiting card' );
    is_deeply( $result->{then}, [], 'then is empty - nothing else to compare against' );
}

done_testing;

__END__

=head1 NAME

342-a-quiet-board-that-changed-type.t - tira.next returns one shape in both states

=head1 DESCRIPTION

C<tira.next> answered with C<{next, then}> - a hash - when work was
waiting, and a bare C<[]> - an array - when nothing was: the same command
returning two different types depending on board state. A caller written
against the documented shape does C<result-E<gt>{next}>, which works every
time the board has work and raises an error the first time it goes quiet.
C<next> is now C<undef> rather than the whole answer being a different
type when nothing is waiting, and C<then> stays an empty array in both
cases. TKT-354.

=cut
