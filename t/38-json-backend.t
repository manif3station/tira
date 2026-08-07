#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;

use lib 'lib';
use Tira;

my $backend = Tira::json_backend();
like( $backend, qr/\A(?:Cpanel::JSON::XS|JSON::PP)\z/,
    'the JSON backend is one of the supported implementations' );
is( Tira::json_backend(), $backend, 'the chosen backend is stable across calls' );
is( Tira::_select_json_backend('No::Such::Json::Module'), 'JSON::PP',
    'an unavailable accelerator falls back to the core pure-Perl backend' );
is( Tira::_select_json_backend( 'No::Such::Json::Module', 'JSON::PP' ), 'JSON::PP',
    'selection walks the candidate list in order' );

# Byte identity with the reference encoder is the whole safety case: stored
# records and content hashes must not shift when an accelerator is present.
my $gnarly = {
    title => "Costs \x{A3}9 \x{4E2D}\x{6587}", priority => 5, ratio => 0.5,
    big => 12345678901234, flag => JSON::PP::true, off => JSON::PP::false,
    nothing => undef, empty_list => [], empty_hash => {},
    nested => { a => [ 1, 2, { b => 'x' } ] },
    slash => 'a/b', quote => 'he said "hi"', tab => "a\tb",
};

is( Tira::json_object()->canonical->utf8->encode($gnarly),
    JSON::PP->new->canonical->utf8->encode($gnarly),
    'canonical encoding is byte-identical to the reference backend' );
is( Tira::json_object()->canonical->pretty->utf8->encode($gnarly),
    JSON::PP->new->canonical->pretty->utf8->encode($gnarly),
    'stored (pretty) encoding is byte-identical, so records never rewrite on upgrade' );
is( Tira::json_object()->canonical->allow_nonref->encode('plain'),
    JSON::PP->new->canonical->allow_nonref->encode('plain'),
    'non-reference encoding matches, so diff comparisons are unaffected' );

my $bytes = JSON::PP->new->canonical->utf8->encode($gnarly);
my $decoded = Tira::json_decode($bytes);
is_deeply( $decoded, JSON::PP::decode_json($bytes), 'decoding matches the reference backend' );
is( ref $decoded->{flag}, 'JSON::PP::Boolean', 'booleans decode to the shared boolean class' );
ok( $decoded->{flag}, 'a true boolean stays true' );
ok( !$decoded->{off}, 'a false boolean stays false' );
is( $decoded->{title}, "Costs \x{A3}9 \x{4E2D}\x{6587}", 'non-ASCII text survives decoding' );
like( JSON::PP->new->canonical->encode( { p => $decoded->{priority} } ), qr/"p":5/,
    'numbers stay JSON numbers rather than becoming strings' );
is( Tira::json_decode( encode_utf8('{"a":1}') )->{a}, 1, 'the decoder accepts UTF-8 bytes like decode_json' );

my $scalar_encoder = Tira::json_object()->canonical->allow_nonref;
is( $scalar_encoder->encode('same'), $scalar_encoder->encode('same'),
    'plain scalars encode for comparison (import diffs rely on it)' );
isnt( $scalar_encoder->encode('a'), $scalar_encoder->encode('b'),
    'differing scalars compare unequal' );

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'backend' );
my $tira = Tira->new( clock => sub { '2026-08-07T10:00:00Z' } );
$tira->create_project( name => 'Backend', dir => $root );
my $ticket = $tira->create_record(
    project => $root, type => 'ticket', title => "Stored \x{A3} record", priority => 4,
);

my ($stored_path) = glob File::Spec->catfile( $root, '.tira', 'ticket', 'backlog', '*.json' );
ok( $stored_path, 'the record file is on disk' );
open my $fh, '<:raw', $stored_path or die $!;
my $raw = do { local $/; <$fh> };
close $fh;
is( $raw, JSON::PP->new->canonical->pretty->utf8->encode( JSON::PP::decode_json($raw) ),
    'the record on disk is byte-for-byte what the reference encoder would write' );

my $shown = $tira->record_show( project => $root, ref => $ticket->{ref} );
is( $shown->{title}, "Stored \x{A3} record", 'records read back through the engine intact' );
is( $shown->{priority}, 4, 'numeric fields survive the round trip' );

my $hashed = $tira->record_show( project => $root, ref => $ticket->{ref}, fields => ['content_hash'] );
my %meaningful = %{$shown};
delete $meaningful{last_updated};
is( $hashed->{content_hash},
    sha256_hex( encode_utf8( JSON::PP->new->canonical->encode( \%meaningful ) ) ),
    'content hashes match the reference encoding, so no hash drifts on upgrade' );

done_testing;

__END__

=head1 NAME

38-json-backend.t - DD-442 optional XS JSON acceleration

=head1 DESCRIPTION

Proves the runtime-selected JSON backend is a drop-in for the core
pure-Perl one: ordered candidate selection with a JSON::PP fallback,
byte-identical canonical, pretty, and non-reference encoding (so stored
records never rewrite and content hashes never drift), and decoding that
preserves booleans, numbers, and non-ASCII text exactly.

=cut
