#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'aging' );
my $tick = '2026-08-08T12:00:00Z';
my $tira = Tira->new( clock => sub { $tick } );
$tira->create_project( name => 'Aging', dir => $root );
$tira->column_add( project => $root, type => 'ticket', name => 'doing', label => 'Doing' );
$tira->column_add( project => $root, type => 'ticket', name => 'review', label => 'Review' );

my $moved = $tira->create_record( project => $root, type => 'ticket', title => 'Moved once' );
my $bounced = $tira->create_record( project => $root, type => 'ticket', title => 'Moved twice' );
my $still = $tira->create_record( project => $root, type => 'ticket', title => 'Never moved' );

$tick = '2026-08-08T12:30:00Z';
$tira->record_move( project => $root, ref => $moved->{ref}, column => 'doing' );
$tick = '2026-08-08T12:40:00Z';
$tira->record_move( project => $root, ref => $bounced->{ref}, column => 'doing' );
$tick = '2026-08-08T13:00:00Z';
$tira->record_move( project => $root, ref => $bounced->{ref}, column => 'review' );

# "Now" is fixed by the clock, so dwell is arithmetic rather than a race.
$tick = '2026-08-08T14:00:00Z';
my $dwell = $tira->dwell_list( project => $root );
my %by_ref = map { $_->{ref} => $_ } @{$dwell};

is( $by_ref{ $moved->{ref} }{column}, 'doing', 'the card reports the column it is in now' );
is( $by_ref{ $moved->{ref} }{since}, '2026-08-08T12:30:00Z',
    'dwell starts at the move into that column' );
is( $by_ref{ $moved->{ref} }{dwell_seconds}, 5400, 'ninety minutes in the column' );
is( $by_ref{ $moved->{ref} }{basis}, 'move', 'and says the measurement came from a move' );

is( $by_ref{ $bounced->{ref} }{column}, 'review', 'a card that moved twice reports its latest column' );
is( $by_ref{ $bounced->{ref} }{dwell_seconds}, 3600,
    'and measures from the most recent move, not the first' );

is( $by_ref{ $still->{ref} }{basis}, 'none',
    'a card that has never moved is reported as having no measurement' );
ok( !defined $by_ref{ $still->{ref} }{dwell_seconds},
    'and carries no invented dwell' );
is( scalar @{$dwell}, 3, 'every card is listed, measured or not' );

# A renamed column must not look like "never moved".
$tira->column_rename( project => $root, type => 'ticket', name => 'review', new_name => 'checking' );
my ($after_rename) = grep { $_->{ref} eq $bounced->{ref} } @{ $tira->dwell_list( project => $root ) };
is( $after_rename->{column}, 'checking', 'the card follows the renamed column' );
is( $after_rename->{basis}, 'move',
    'and still measures from its move, even though the move names the old column' );
is( $after_rename->{dwell_seconds}, 3600, 'with the same dwell as before the rename' );

# An unreadable timestamp must not take the whole board down.
my ($journal) = glob File::Spec->catfile( $root, '.tira', 'history', $moved->{ref} . '.jsonl' );
ok( $journal, 'the journal is where dwell reads from' );
($journal) = $journal =~ /\A(.+\.jsonl)\z/s;
open my $corrupt, '>>:raw', $journal or die $!;
print {$corrupt} qq({"at":"not-a-timestamp","ref":"$moved->{ref}","field":"column","op":"move","before":"doing","after":"doing"}\n);
close $corrupt;
my ($unreadable) = grep { $_->{ref} eq $moved->{ref} } @{ $tira->dwell_list( project => $root ) };
is( $unreadable->{basis}, 'unknown', 'an unreadable stamp is reported as unknown' );
ok( !defined $unreadable->{dwell_seconds}, 'and yields no number' );
is( scalar @{ $tira->dwell_list( project => $root ) }, 3, 'the rest of the board still reports' );

my $older = $tira->dwell_list( project => $root, older_than => 45 );
is_deeply( [ map { $_->{ref} } @{$older} ], [ $bounced->{ref} ],
    'older-than keeps only cards past that many minutes, and never the unmeasured' );
is_deeply( $tira->dwell_list( project => $root, older_than => 1000 ), [],
    'a threshold nothing has reached returns an explicit empty list' );

my $sow = $tira->create_record( project => $root, type => 'sow', title => 'A statement' );
$tick = '2026-08-08T14:30:00Z';
$tira->column_add( project => $root, type => 'sow', name => 'drafting', label => 'Drafting' );
$tira->record_move( project => $root, ref => $sow->{ref}, column => 'drafting' );
$tick = '2026-08-08T15:00:00Z';
ok( scalar( grep { $_->{ref} eq $sow->{ref} } @{ $tira->dwell_list( project => $root ) } ),
    'all three boards are covered in one call' );
is( scalar @{ $tira->dwell_list( project => $root, type => 'ticket' ) }, 3,
    'and a single board can still be asked for on its own' );

sub run_cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => 'stale', argv => \@argv, tira => $tira );
    return ( $status, $out, $err );
}

my ( $status, $out, $err ) = run_cli( '--project', $root, '-o', 'json' );
is( $status, 0, 'the stale command succeeds' );
my $payload = decode_json($out);
is( ref $payload, 'ARRAY', 'it returns a list' );
is( scalar @{$payload}, 4, 'covering every card on every board' );

( $status, $out, $err ) = run_cli( '--project', $root, '--older-than', '45', '-o', 'json' );
is( scalar @{ decode_json($out) }, 1, 'the CLI filters by age' );

( $status, $out, $err ) = run_cli( '--project', $root, '--older-than', 'soon', '-o', 'json' );
is( $status, 2, 'a non-numeric age exits 2' );
like( $err, qr/older-than/i, 'and names the option' );

done_testing;

__END__

=head1 NAME

44-dwell.t - DD-458 column dwell and the stale report

=head1 DESCRIPTION

Proves how long each card has sat in the column it is in now: measured
from its most recent column move, skipped rather than invented when no
move was ever recorded, unaffected by a column being renamed underneath
it, degrading to unknown on an unreadable timestamp rather than failing
the whole board, filterable by age, and covering all three boards in a
single call.

=cut
