#!/usr/bin/env perl

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'attachments' );
my $tira = Tira->new( clock => sub { '2026-08-05T17:00:00Z' } );
$tira->create_project( name => 'Attachment truth', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
my $first_dir = File::Spec->catdir( $tmp, 'one' );
my $second_dir = File::Spec->catdir( $tmp, 'two' );
make_path( $first_dir, $second_dir );
my $first_file = File::Spec->catfile( $first_dir, 'first-name.txt' );
my $second_file = File::Spec->catfile( $second_dir, 'second-name.txt' );
for my $file ( $first_file, $second_file ) {
    open my $fh, '>:raw', $file or die $!;
    print {$fh} "identical content\n";
    close $fh;
}

my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'One' );
my $first = $tira->attachment_add( project => $root, ref => $ticket->{ref}, file => $first_file );
is( $first->{original_filename}, 'first-name.txt', 'new add returns stored filename' );
is( $first->{supplied_filename}, 'first-name.txt', 'new add returns supplied filename' );
ok( !$first->{deduped}, 'new record reference is not deduped' );

my $second = $tira->attachment_add( project => $root, ref => $ticket->{ref}, file => $second_file );
is( $second->{original_filename}, 'first-name.txt', 'duplicate returns retained filename' );
is( $second->{supplied_filename}, 'second-name.txt', 'duplicate returns rejected supplied filename' );
ok( $second->{deduped}, 'duplicate reports record-level deduplication' );
is_deeply( $tira->attachment_list( project => $root, ref => $ticket->{ref} ),
    [ { sha => $first->{sha}, extension => 'txt', original_filename => 'first-name.txt',
        added_at => '2026-08-05T17:00:00Z', attached_to => 'card' } ],
    'record stores one truthful reference, and says where it hangs' );

$tira->attachment_remove( project => $root, sha => $first->{sha}, extension => 'txt' );
my $restored = $tira->attachment_add( project => $root, ref => $ticket->{ref}, file => $second_file );
is( $restored->{original_filename}, 'first-name.txt', 'restore still returns retained filename' );
is( $restored->{supplied_filename}, 'second-name.txt', 'restore reports supplied filename' );
ok( $restored->{deduped}, 'restore reports retained reference deduplication' );

my $other = $tira->create_record( project => $root, type => 'ticket', title => 'Two' );
my $other_add = $tira->attachment_add( project => $root, ref => $other->{ref}, file => $second_file );
is( $other_add->{original_filename}, 'second-name.txt', 'another record retains its own filename' );
ok( !$other_add->{deduped}, 'another record gets a new reference despite shared content' );

my $comment = $tira->comment_add( project => $root, ref => $ticket->{ref}, author => 'ada', text => 'Evidence' );
my $comment_first = $tira->attachment_add(
    project => $root, ref => $ticket->{ref}, comment => $comment->{id}, file => $second_file,
);
ok( !$comment_first->{deduped}, 'comment attachment list deduplicates independently' );
is( $comment_first->{original_filename}, 'second-name.txt', 'comment retains its supplied filename' );
my $comment_second = $tira->attachment_add(
    project => $root, ref => $ticket->{ref}, comment => $comment->{id}, file => $first_file,
);
is( $comment_second->{original_filename}, 'second-name.txt', 'comment duplicate returns comment-retained filename' );
is( $comment_second->{supplied_filename}, 'first-name.txt', 'comment duplicate reports supplied filename' );
ok( $comment_second->{deduped}, 'comment duplicate reports deduplication' );

local $ENV{TIRA_HOME} = $root;
my ( $stdout, $stderr ) = ('', '');
{
    open my $out, '>', \$stdout or die $!;
    open my $err, '>', \$stderr or die $!;
    local *STDOUT = $out;
    local *STDERR = $err;
    is( Tira::CLI->run(
        command => 'attachment.add',
        argv => [ '--ref', $ticket->{ref}, '--file', $second_file, '-o', 'json' ],
    ), 0, 'CLI duplicate attachment succeeds' );
}
is( $stderr, '', 'CLI duplicate attachment has no stderr' );
my $result = decode_json($stdout);
is( $result->{original_filename}, 'first-name.txt', 'CLI returns stored filename' );
is( $result->{supplied_filename}, 'second-name.txt', 'CLI returns supplied filename' );
ok( $result->{deduped}, 'CLI explicitly reports deduplication' );

done_testing;

__END__

=head1 NAME

12-attachment-dedup-response.t - Truthful attachment deduplication responses

=head1 DESCRIPTION

Proves record- and comment-scoped filename retention, explicit response
metadata, restore behavior, cross-record names, and JSON CLI output.

=cut
