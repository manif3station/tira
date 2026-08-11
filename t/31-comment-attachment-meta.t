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
my $root = File::Spec->catdir( $tmp, 'threads' );
my $tick = '2026-08-07T07:00:00Z';
my $tira = Tira->new( clock => sub { $tick } );
$tira->create_project( name => 'Threads', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Threaded' );
my $ref = $ticket->{ref};

my @stamps = ( '2026-08-07T07:01:00Z', '2026-08-07T07:02:00Z', '2026-08-07T07:03:00Z' );
for my $index ( 0 .. 2 ) {
    $tick = $stamps[$index];
    $tira->comment_add( project => $root, ref => $ref, author => 'ada', text => 'Comment ' . ( $index + 1 ) );
}

my $file = File::Spec->catfile( $tmp, 'evidence.txt' );
open my $fh, '>:raw', $file or die $!;
print {$fh} "EVIDENCE BYTES\n";
close $fh;
$tick = '2026-08-07T07:04:00Z';
$tira->attachment_add( project => $root, ref => $ref, file => $file );

my $newest = $tira->comment_list( project => $root, ref => $ref, last => 1 );
is( scalar @{$newest}, 1, 'last 1 returns exactly one comment' );
is( $newest->[0]{body}, 'Comment 3', 'the newest comment is the one returned' );

is( scalar @{ $tira->comment_list( project => $root, ref => $ref, last => 9 ) },
    3, 'a window larger than the total returns everything without error' );
my $first_two = $tira->comment_list( project => $root, ref => $ref, first => 2 );
is_deeply( [ map { $_->{body} } @{$first_two} ], [ 'Comment 1', 'Comment 2' ],
    'first N returns the original context in stored order' );

eval { $tira->comment_list( project => $root, ref => $ref, first => 1, last => 1 ) };
like( $@, qr/Cannot combine --first with --last/, 'contradictory windows fail loudly' );
eval { $tira->comment_list( project => $root, ref => $ref, last => -1 ) };
like( $@, qr/zero or a positive count/, 'negative windows are refused' );

is_deeply( $tira->comment_list( project => $root, ref => $ref, last => 0 ),
    { count => 3 }, 'a zero window is an existence check with the count' );
is_deeply( $tira->comment_list( project => $root, ref => $ref, count => 1 ),
    { count => 3 }, 'count mode matches' );

my $meta = $tira->comment_list( project => $root, ref => $ref, meta_only => 1 );
ok( !exists $meta->[0]{body}, 'meta-only omits the body' );
is( $meta->[2]{body_length}, length 'Comment 3', 'the body length is reported for budgeting' );
is( $meta->[0]{attachment_count}, 0, 'the per-comment attachment count is included' );
is( $meta->[0]{author}, 'ada', 'attribution survives' );
ok( $meta->[0]{id}, 'ids are always returned' );

eval { $tira->comment_list( project => $root, ref => $ref, meta_only => 1, fields => ['body'] ) };
like( $@, qr/Meta-only contradicts selecting the body/, 'meta-only with a body selection fails' );

my $authors = $tira->comment_list( project => $root, ref => $ref, last => 1, fields => ['author'] );
is_deeply( [ sort keys %{ $authors->[0] } ], [qw(author id)],
    'comment field selection keeps the id plus the named field' );
eval { $tira->comment_list( project => $root, ref => $ref, fields => ['nosuchfield'] ) };
like( $@, qr/Unknown comment field 'nosuchfield'/, 'unknown comment fields fail naming the offender' );

is( scalar @{ $tira->comment_list( project => $root, ref => $ref, since => '2026-08-07T07:02:30Z' ) },
    1, 'since filters comments by their own stamps' );

my $shown = $tira->record_show( project => $root, ref => $ref, meta_only => 1 );
ok( !exists $shown->{comments}[0]{body}, 'record-level meta-only strips embedded comment bodies' );
is( $shown->{comments}[0]{body_length}, length 'Comment 1', 'embedded metadata keeps the length' );
my $board = $tira->export_records( project => $root, meta_only => 1 );
ok( !exists $board->{records}[0]{comments}[0]{body}, 'export meta-only works board-wide' );

my $attachments = $tira->attachment_list( project => $root, ref => $ref, meta_only => 1 );
is( $attachments->{count}, 1, 'attachment meta returns an envelope with the count' );
my $entry = $attachments->{attachments}[0];
is( $entry->{filename}, 'evidence.txt', 'the stored filename is assembled' );
is( $entry->{size}, length "EVIDENCE BYTES\n", 'the real byte size is reported' );
is( $entry->{content_type}, 'text/plain; charset=UTF-8', 'the content type comes from the extension map' );
is( $entry->{added_at}, '2026-08-07T07:04:00Z', 'the added time is included' );
like( $entry->{sha}, qr/\A[0-9a-f]{64}\z/, 'the sha is included for re-upload detection' );
is( $attachments->{total_size}, $entry->{size}, 'the total size is returned for budgeting' );

my $names = $tira->attachment_list( project => $root, ref => $ref, fields => ['filename'] );
is_deeply( [ sort keys %{ $names->[0] } ], [qw(filename sha)],
    'attachment field selection keeps the sha plus the named field' );
is_deeply( $tira->attachment_list( project => $root, ref => $ref, count => 1 ),
    { count => 1 }, 'attachment count mode works' );
is( scalar @{ $tira->attachment_list( project => $root, ref => $ref, since => '2026-08-07T09:00:00Z', fields => ['filename'] ) },
    0, 'attachment since filters by added time' );
eval { $tira->attachment_list( project => $root, meta_only => 1 ) };
like( $@, qr/require --ref/, 'attachment read options without a ref fail loudly' );

my $counted = $tira->record_show( project => $root, ref => $ref, fields => ['attachment_count'] );
is( $counted->{attachment_count}, 1, 'attachment_count is a selectable computed record field' );
my $coverage = $tira->export_records( project => $root, fields => ['attachment_count'] );
is( $coverage->{records}[0]{attachment_count}, 1, 'attachment_count works board-wide through export' );

my $second_file = File::Spec->catfile( $tmp, 'later.txt' );
open my $second_fh, '>:raw', $second_file or die $!;
print {$second_fh} "LATER BYTES LONGER\n";
close $second_fh;
$tick = '2026-08-07T07:10:00Z';
$tira->attachment_add( project => $root, ref => $ref, file => $second_file );
my $ordered = $tira->attachment_list( project => $root, ref => $ref, meta_only => 1 );
is_deeply( [ map { $_->{filename} } @{ $ordered->{attachments} } ],
    [ 'later.txt', 'evidence.txt' ], 'attachment metadata lists newest evidence first' );
is( $ordered->{total_size}, length("EVIDENCE BYTES\n") + length("LATER BYTES LONGER\n"),
    'the total size sums every entry' );

sub run_cli {
    my ( $command, $type, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run(
        command => $command, ( defined $type ? ( type => $type ) : () ), argv => \@argv,
    );
    return ( $status, $out, $err );
}

my ( $status, $out, $err ) = run_cli(
    'comment.list', undef, '--project', $root, '--ref', $ref, '--last', '1', '-o', 'json',
);
is( $status, 0, 'CLI comment window succeeds' );
my $payload = decode_json($out);
is( $payload->[0]{body}, 'Comment 3', 'the CLI returns the newest comment' );

( $status, $out, $err ) = run_cli(
    'comment.list', undef, '--project', $root, '--ref', $ref, '--meta-only', '-o', 'json',
);
ok( !exists decode_json($out)->[0]{body}, 'CLI meta-only omits bodies' );

( $status, $out, $err ) = run_cli(
    'attachment.list', undef, '--project', $root, '--ref', $ref, '--meta-only', '-o', 'json',
);
is( decode_json($out)->{attachments}[0]{filename}, 'later.txt', 'CLI attachment metadata works, newest first' );

( $status, $out, $err ) = run_cli(
    'record.list', 'ticket', '--project', $root, '--last', '1', '-o', 'json',
);
is( $status, 2, 'windows outside comment lists exit 2' );
like( $err, qr/comment, gate, evidence, and history/, 'the window error names every list it applies to' );

( $status, $out, $err ) = run_cli(
    'record.update', 'ticket', '--project', $root, '--ref', $ref,
    '--title', 'Nope', '--meta-only', '-o', 'json',
);
is( $status, 2, 'meta-only on a mutation exits 2' );

done_testing;

__END__

=head1 NAME

31-comment-attachment-meta.t - comment windows and metadata reads (CA10-CA12)

=head1 DESCRIPTION

Proves C<--last>/C<--first> comment windows (newest-last order, oversize
windows safe, zero as existence check, contradictions loud), comment
C<--meta-only> with body length and attachment counts (record- and
board-level too), comment-level field selection with ids always kept,
attachment C<--meta-only> enrichment (filename, real size, content type,
added time, sha, total size envelope), attachment field selection and
counts, since on both, the selectable C<attachment_count> record field,
and CLI guards.

=cut
