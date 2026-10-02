#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

# TKT-1205. d2 tira.doctor on a board whose .tira directory also holds another
# tool's SQLite database in WAL mode reported telegram.messages.db-shm and
# telegram.messages.db-wal as damaged: invalid UTF-8 byte offsets, repaired[0].
# Both are binary by design and the database itself was healthy. Doctor already
# skipped a path ending in .db (the notification database); the sidecars SQLite
# keeps beside it - -wal, -shm and -journal - matched no skip, so both of
# doctor's walkers read them as Tira text files. Under --repair that would not
# just be a false alarm: it would rewrite another tool's live database files.
#
# What is held here: no sidecar is reported or repaired, in either walker (the
# byte scan and the card-shape scan); a real damaged card beside them is still
# found; the skip is anchored to the suffix, so a text file that merely mentions
# one is still scanned; and the main .db skip is unchanged.

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub { '2026-10-02T01:20:00Z' } );
$tira->project_new( name => 'Proj', dir => $root, members => ['claude'] );

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card beside the sidecars', author => 'claude',
    description => 'd', problem_or_feature => 'p', solution_needed => 's',
);
my $home = File::Spec->catdir( $root, '.tira' );

sub write_bytes {
    my ( $name, $bytes ) = @_;
    my $path = File::Spec->catfile( $home, $name );
    open my $fh, '>:raw', $path or die "Cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

sub read_bytes {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot read $path: $!";
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return $bytes;
}

# Binary, with bytes no UTF-8 decoder accepts - what SQLite really writes.
my $binary = "\x37\x7f\x06\x82\xff\xfe\x00\x01 not text \xc3\x28";

# The same bytes shaped as a card record whose evidence is a string, which the
# shape walker would call damaged if it were ever allowed to parse it.
my $record_shaped = '{"ref":"TKT-1","evidence":"a plain string, not an array"}';

my %sidecar = map { $_ => write_bytes( "telegram.messages.db$_", $binary ) } qw(-wal -shm -journal);
my $shaped = write_bytes( 'telegram.other.db-wal', $record_shaped );
my $main   = write_bytes( 'telegram.messages.db', $binary );

# Control: the suffix is anchored. A file that only contains the word is Tira's
# to scan and must still be reported.
my $mention = write_bytes( 'notes.db-wal.txt', "caf\xe9 is not UTF-8\n" );

my %before = map { $_ => read_bytes($_) } ( values %sidecar, $shaped, $main, $mention );

my $found = $tira->doctor( project => $root );
my %reported = map { $_->{path} => 1 } @{ $found->{damaged} };

for my $suffix ( sort keys %sidecar ) {
    ok( !$reported{ $sidecar{$suffix} }, "db$suffix is not reported as damaged" );
}
ok( !$reported{$shaped}, 'a sidecar that happens to parse as a card record is not reported by the shape scan either' );
ok( !$reported{$main},   'the main .db is still skipped, as it always was' );
ok( $reported{$mention}, 'a text file that only mentions .db-wal in its name is still scanned and reported' );

# --- a real damaged card beside the sidecars is still found ------------------

my ($card_path) = glob File::Spec->catfile( $home, 'ticket', '*', "$card->{ref}.json" );
ok( -f $card_path, 'the card file exists where doctor looks' );
open my $in, '<:raw', $card_path or die $!;
my $json = do { local $/; <$in> };
close $in;
$json =~ s/"title"\s*:\s*"A card beside the sidecars"/"title" : "A card beside the sidecars \xff"/ or die 'title not found in the card';
open my $out, '>:raw', $card_path or die $!;
print {$out} $json;
close $out;

my $again = $tira->doctor( project => $root );
my %now = map { $_->{path} => 1 } @{ $again->{damaged} };
ok( $now{$card_path}, 'a genuinely damaged card is still reported' );
ok( !$now{$sidecar{'-wal'}}, 'and the sidecar beside it still is not' );

# --- --repair rewrites nothing that is not Tira's -----------------------------

my $repaired = $tira->doctor( project => $root, repair => 1 );
my %mended = map { $_->{path} => 1 } @{ $repaired->{repaired} };
ok( $mended{$card_path}, '--repair still mends the damaged card' );
ok( $mended{$mention},   'and still mends the text file doctor owns' );

for my $path ( values %sidecar, $shaped, $main ) {
    ok( !$mended{$path}, "--repair does not list $path as repaired" );
    is( read_bytes($path), $before{$path}, "$path is byte-for-byte what it was" );
}

done_testing;

__END__

=head1 NAME

1205-doctor-leaves-sqlite-sidecars-alone.t - doctor does not scan SQLite -wal, -shm and -journal files

=head1 DESCRIPTION

TKT-1205. C<d2 tira.doctor> reported a healthy SQLite database's C<-wal> and
C<-shm> sidecars as damaged because only the C<.db> file itself was skipped.
This file holds that no sidecar is reported or repaired by either scanner, that
a damaged Tira card beside them is still found and mended, that the skip is
anchored to the suffix, and that the sidecars are byte-for-byte unchanged after
a C<--repair>.

=cut
