#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Encode qw(decode_utf8 encode_utf8);
use HTTP::Request::Common qw(GET POST);
use JSON::PP qw(decode_json);
use MIME::Base64 qw(encode_base64);
use Plack::Test;
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'attachments' );
my $tira = Tira->new( clock => sub { '2026-08-06T18:00:00+0100' } );
$tira->create_project( name => 'Attachment project', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
$tira->create_record( project => $root, type => 'ticket', title => 'Carrier' );
$tira->comment_add( project => $root, ref => 'TKT-001', author => 'ada', text => 'host comment' );

my $pound = chr 0xA3;

sub browser_cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err, @calls ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run(
        command => $command, argv => \@argv, tira => $tira,
        browser_server => sub { push @calls, { @_ }; return 1 },
    );
    return ( $status, $out, $err, \@calls );
}

my ( $status, undef, undef, $calls ) =
  browser_cli( 'dashboard.ticket', '--project', $root, '--title', '-o', 'browser' );
is( $status, 0, 'browser dashboard starts with attachment providers' );

for my $provider (qw(attachment_fetch attachment_add attachment_remove)) {
    is( ref $calls->[0]{$provider}, 'CODE', "browser server receives an $provider provider" );
}

my $live_html = $calls->[0]{render}->();
like( $live_html, qr/card-attachment/, 'the dialog renders attachment chips' );
like( $live_html, qr{"/attachment\?}, 'the viewer sources bytes from the attachment route' );
like( $live_html, qr{mutate\("/attachment/add"}, 'uploads post to the attachment add route' );
like( $live_html, qr{mutate\("/attachment/remove"}, 'deletion posts to the attachment remove route' );
like( $live_html, qr/card-viewer/, 'the dialog includes the overlay viewer' );
like( $live_html, qr/FileReader/, 'uploads read the picked file in the browser' );

my $added = decode_json( encode_utf8( $calls->[0]{attachment_add}->( {
    ref => 'TKT-001', filename => "receipt ${pound}.txt",
    content_base64 => encode_base64( encode_utf8("cost ${pound}9\n"), '' ),
} ) ) );
ok( $added->{ok}, 'the attachment add provider stores content' );
is( $added->{attachment}{extension}, 'txt', 'the stored extension is reported' );
my $sha = $added->{attachment}{sha};
like( $sha, qr/\A[0-9a-f]{64}\z/, 'the stored sha is reported' );

my $fetched = $calls->[0]{attachment_fetch}->( { ref => 'TKT-001', sha => $sha, extension => 'txt' } );
is( ref $fetched, 'HASH', 'the fetch provider returns a typed payload' );
is( $fetched->{content_type}, 'text/plain; charset=UTF-8', 'text attachments are served as plain text' );
is( decode_utf8( $fetched->{content} ), "cost ${pound}9\n", 'the fetched bytes match the upload' );

my $comment_added = decode_json( $calls->[0]{attachment_add}->( {
    ref => 'TKT-001', comment => 'CMT-001', filename => 'diagram.png',
    content_base64 => encode_base64( "\x89PNG\r\n\x1a\nfake", '' ),
} ) );
ok( $comment_added->{ok}, 'comment-scoped uploads succeed' );
is( $tira->record_show( project => $root, ref => 'TKT-001' )->{comments}[0]{attachments}[0]{extension},
    'png', 'the upload landed on the comment' );
my $png_fetch = $calls->[0]{attachment_fetch}->( { ref => 'TKT-001', sha => $comment_added->{attachment}{sha}, extension => 'png' } );
is( $png_fetch->{content_type}, 'image/png', 'png attachments are served with an image type' );

my $zip_added = decode_json( $calls->[0]{attachment_add}->( {
    ref => 'TKT-001', filename => 'bundle.zip',
    content_base64 => encode_base64( 'PK-fake-zip-bytes', '' ),
} ) );
my $zip_fetch = $calls->[0]{attachment_fetch}->( { ref => 'TKT-001', sha => $zip_added->{attachment}{sha}, extension => 'zip' } );
is( $zip_fetch->{content_type}, 'application/octet-stream', 'unpreviewable types fall back to octet-stream' );
ok( !$zip_fetch->{inline}, 'octet-stream attachments are served as downloads, not inline' );
is( $zip_fetch->{filename}, 'bundle.zip', 'the download keeps its original filename' );

my $video_added = decode_json( $calls->[0]{attachment_add}->( {
    ref => 'TKT-001', filename => 'demo.mp4',
    content_base64 => encode_base64( 'FAKE-MP4-BYTES-0123456789', '' ),
} ) );
my $video_fetch = $calls->[0]{attachment_fetch}->( { ref => 'TKT-001', sha => $video_added->{attachment}{sha}, extension => 'mp4' } );
is( $video_fetch->{content_type}, 'video/mp4', 'mp4 attachments are served as video' );
ok( $video_fetch->{inline}, 'video attachments are served inline for the player' );
my $tiff_added = decode_json( $calls->[0]{attachment_add}->( {
    ref => 'TKT-001', filename => 'scan.tiff',
    content_base64 => encode_base64( 'II*FAKE-TIFF', '' ),
} ) );
my $tiff_fetch = $calls->[0]{attachment_fetch}->( { ref => 'TKT-001', sha => $tiff_added->{attachment}{sha}, extension => 'tiff' } );
is( $tiff_fetch->{content_type}, 'image/tiff', 'tiff attachments are served as image/tiff' );
my $audio_fetch_type = Tira::CLI::_attachment_content_type('mp3');
is( $audio_fetch_type, 'audio/mpeg', 'mp3 maps to audio' );

my $removed = decode_json( $calls->[0]{attachment_remove}->( { ref => 'TKT-001', sha => $sha, extension => 'txt' } ) );
ok( $removed->{ok}, 'the attachment remove provider detaches' );
my $remaining = $tira->record_show( project => $root, ref => 'TKT-001' )->{attachments};
is( scalar @{$remaining}, 3, 'only the detached reference is removed through the browser provider' );
is_deeply( [ sort map { $_->{extension} } @{$remaining} ], [ 'mp4', 'tiff', 'zip' ],
    'the untouched attachment references survive' );

my $error = eval { $calls->[0]{attachment_add}->( { ref => 'TKT-001', filename => 'x.txt' } ); 1 } ? '' : $@;
like( $error, qr/requires/i, 'upload payloads must carry content' );
$error = eval { $calls->[0]{attachment_fetch}->( { ref => 'TKT-001', sha => 'f' x 64, extension => 'txt' } ); 1 } ? '' : $@;
like( $error, qr/not found/i, 'fetching an unknown attachment dies clearly' );

my %providers = (
    render => sub { '<!doctype html>' }, data => sub { '{}' },
    move => sub { '{}' }, detail => sub { '{}' },
    search => sub { '[]' },
    columns => sub { '[]' },
    question_answer => sub { '{"ok":true}' },
    question_mark => sub { '{"ok":true}' },
    column_apply => sub { '{}' },
    create => sub { '{"ok":true,"record":{"ref":"TKT-009"}}' },
    update => sub { '{}' }, comment_add => sub { '{}' },
    comment_update => sub { '{}' }, comment_remove => sub { '{}' },
    people => sub { '[]' },
    attachment_fetch => sub { return { content => "BYTES ${pound}", content_type => 'text/plain; charset=UTF-8', filename => 'a.txt' } },
    attachment_add => sub { return '{"ok":true,"attachment":{"sha":"00"}}' },
    attachment_remove => sub { die "Attachment 'ff' is not attached\n" },
    checklist_add => sub { return '{"ok":true}' },
    checklist_update => sub { return '{"ok":true}' },
    link_types => sub { '[]' },
    hierarchy_link => sub { '{"ok":true}' },
    hierarchy_unlink => sub { '{"ok":true}' },
    subitem_link => sub { '{"ok":true}' },
    subitem_unlink => sub { '{"ok":true}' },
    link_add => sub { '{"ok":true}' },
    link_remove => sub { '{"ok":true}' },
);

for my $missing (qw(attachment_fetch attachment_add attachment_remove)) {
    my %incomplete = %providers;
    delete $incomplete{$missing};
    eval { Tira::DashboardWeb->build_psgi_app(%incomplete) };
    ( my $label = $missing ) =~ tr/_/ /;
    like( $@, qr/Missing dashboard \Q$label\E provider/, "PSGI builder requires the $missing provider" );
}

my $app = Tira::DashboardWeb->build_psgi_app(%providers);
test_psgi $app, sub {
    my ($client) = @_;

    my $fetch = $client->( GET '/attachment?ref=TKT-001&sha=' . ( '0' x 64 ) . '&extension=txt' );
    is( $fetch->code, 200, 'the attachment route streams' );
    like( $fetch->header('Content-Type'), qr{text/plain}, 'the provider content type is used' );
    is( decode_utf8( $fetch->content ), "BYTES ${pound}", 'attachment bytes round-trip UTF-8 safely' );
    is( $fetch->header('Accept-Ranges'), 'bytes', 'the route advertises byte ranges' );

    my $partial = $client->( GET '/attachment?ref=TKT-001&sha=' . ( '0' x 64 ) . '&extension=txt', Range => 'bytes=0-4' );
    is( $partial->code, 206, 'a range request answers partial content' );
    is( $partial->content, 'BYTES', 'the requested byte slice is returned' );
    like( $partial->header('Content-Range'), qr{\Abytes 0-4/\d+\z}, 'the content range names the slice and total' );

    my $tail = $client->( GET '/attachment?ref=TKT-001&sha=' . ( '0' x 64 ) . '&extension=txt', Range => 'bytes=6-' );
    is( $tail->code, 206, 'an open-ended range answers partial content' );
    is( decode_utf8( $tail->content ), $pound, 'the open-ended slice reaches the end' );

    my $bogus = $client->( GET '/attachment?ref=TKT-001&sha=' . ( '0' x 64 ) . '&extension=txt', Range => 'bytes=99-' );
    is( $bogus->code, 200, 'an unsatisfiable range falls back to the full body' );

    my $add = $client->(
        POST '/attachment/add', Content_Type => 'application/json',
        Content => '{"ref":"TKT-001","filename":"a.txt","content_base64":"QQ=="}',
    );
    is( $add->code, 200, 'the attachment add route responds' );
    ok( decode_json( $add->content )->{ok}, 'the add route returns the provider result' );

    my $remove = $client->(
        POST '/attachment/remove', Content_Type => 'application/json',
        Content => '{"ref":"TKT-001","sha":"ff"}',
    );
    is( $remove->code, 422, 'a failing detach is unprocessable' );
    like( decode_json( $remove->content )->{error}, qr/not attached/, 'the detach failure carries the engine error' );
};

my $missing_fetch = Tira::DashboardWeb->build_psgi_app(
    %providers, attachment_fetch => sub { die "Attachment 'ff' not found\n" },
);
test_psgi $missing_fetch, sub {
    my ($client) = @_;
    my $fetch = $client->( GET '/attachment?ref=TKT-001&sha=' . ( 'f' x 64 ) . '&extension=txt' );
    is( $fetch->code, 404, 'an unknown attachment answers 404' );
};

done_testing;

__END__

=head1 NAME

21-dashboard-attachments.t - dialog attachment providers and routes

=head1 DESCRIPTION

Guards the browser attachment providers (typed fetch, base64 upload with
comment scoping, reference-safe removal), the dialog markup contract (chips,
viewer overlay, upload reader, mutation routes), and the Dancer2 attachment
routes' streaming, 422, and 404 semantics.

=cut
