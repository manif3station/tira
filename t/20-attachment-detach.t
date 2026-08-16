#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $now = '2026-08-06T17:00:00+0100';
my $tira = Tira->new( clock => sub { $now } );
my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'detach' );
$tira->create_project( name => 'Detach project', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
$tira->create_record( project => $root, type => 'ticket', title => 'First' );
$tira->create_record( project => $root, type => 'ticket', title => 'Second' );
$tira->comment_add( project => $root, ref => 'TKT-001', author => 'ada', text => 'with file' );

my $pound = chr 0xA3;

# Content-based upload twin of attachment_add: same dedup, no temp file.
my $stored = $tira->attachment_add_content(
    project => $root, ref => 'TKT-001', filename => "receipt ${pound}.txt", content => "cost ${pound}9\n",
);
is( $stored->{extension}, 'txt', 'content upload derives the extension from the filename' );
like( $stored->{sha}, qr/\A[0-9a-f]{64}\z/, 'content upload stores by content hash' );
is( $stored->{original_filename}, "receipt ${pound}.txt", 'the UTF-8 original filename is retained' );
ok( !$stored->{deduped}, 'first upload is not a dedup hit' );

my $sha = $stored->{sha};
my $stored_path = File::Spec->catfile( $root, '.tira', 'attachments', "$sha.txt" );
ok( -f $stored_path, 'content upload writes the deduplicated store file' );

my $again = $tira->attachment_add_content(
    project => $root, ref => 'TKT-002', filename => 'copy.txt', content => "cost ${pound}9\n",
);
ok( $again->{deduped} || $again->{sha} eq $sha, 'identical content dedups across records' );

my $on_comment = $tira->attachment_add_content(
    project => $root, ref => 'TKT-001', comment => 'CMT-001',
    filename => 'note.md', content => "comment file\n",
);
is( ( $tira->record_show( project => $root, ref => 'TKT-001' )->{comments}[0]{attachments}[0]{sha} ),
    $on_comment->{sha}, 'a comment upload is owned by the comment, not the record strip' );

{
    my $error = eval {
        $tira->attachment_add_content( project => $root, ref => 'TKT-001', filename => 'x.txt', content => 'x' x ( 16 * 1024 * 1024 + 1 ) );
        1;
    } ? '' : $@;
    like( $error, qr/too large/i, 'oversized content uploads are refused' );
}

# Reference-safe detach: the record loses the reference; the stored file
# survives while any other record still references the same content.
my $detached = $tira->attachment_detach( project => $root, ref => 'TKT-001', sha => $sha, extension => 'txt' );
ok( $detached->{detached}, 'detach reports success' );
ok( !$detached->{removed_from_store}, 'the store keeps a file still referenced elsewhere' );
is( scalar @{ $tira->record_show( project => $root, ref => 'TKT-001' )->{attachments} },
    0, 'the record reference is gone' );
ok( -f $stored_path, 'the deduplicated file survives for the other record' );

my $last = $tira->attachment_detach( project => $root, ref => 'TKT-002', sha => $sha, extension => 'txt' );
ok( $last->{removed_from_store}, 'detaching the last reference removes the stored file' );
ok( !-f $stored_path, 'the stored file is physically gone' );
my $log = File::Spec->catfile( $root, '.tira', 'attachments', 'delete.log.yml' );
ok( -f $log, 'physical removal is permanently logged' );

my $comment_detach = $tira->attachment_detach(
    project => $root, ref => 'TKT-001', comment => 'CMT-001', sha => $on_comment->{sha}, extension => 'md',
);
ok( $comment_detach->{removed_from_store}, 'a comment-owned attachment detaches and clears the store when unreferenced' );
is( scalar @{ $tira->record_show( project => $root, ref => 'TKT-001' )->{comments}[0]{attachments} },
    0, 'the comment reference is gone' );

{
    my $error = eval { $tira->attachment_detach( project => $root, ref => 'TKT-001', sha => 'a' x 64, extension => 'txt' ); 1 } ? '' : $@;
    like( $error, qr/not attached/i, 'detaching a reference the record does not hold dies clearly' );
}

sub run_cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $command = shift @argv;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => $command, argv => \@argv, tira => $tira );
    return ( $status, $out, $err );
}

{
    my $cli_stored = $tira->attachment_add_content(
        project => $root, ref => 'TKT-002', filename => 'cli.txt', content => "cli detach\n",
    );
    my ( $status, $out, $err ) = run_cli(
        'attachment.detach', '--ref', 'TKT-002',
        '--sha', $cli_stored->{sha}, '--extension', 'txt', '-o', 'json',
    );
    is( $status, 0, 'tira.attachment.detach succeeds through the CLI' );
    is( $err, '', 'CLI detach has no stderr' );
    my $payload = decode_json($out);
    ok( $payload->{detached}, 'the CLI reports the detach' );
    ok( $payload->{removed_from_store}, 'the CLI reports the store removal for a sole reference' );
}

done_testing;

__END__

=head1 NAME

20-attachment-detach.t - content uploads and reference-safe attachment detach

=head1 DESCRIPTION

Guards attachment_add_content (sha dedup without temp files, UTF-8 filenames,
size cap), attachment_detach (record- and comment-scoped reference removal
with store cleanup only when globally unreferenced, logged), and the
tira.attachment.detach CLI verb.

=cut
