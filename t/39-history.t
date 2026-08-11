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
my $root = File::Spec->catdir( $tmp, 'chronicle' );
my $tick = '2026-08-07T12:00:00Z';
my $tira = Tira->new( clock => sub { $tick } );
$tira->create_project( name => 'Chronicle', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
$tira->person_add( project => $root, id => 'grace', name => 'Grace' );

my $ticket = $tira->create_record(
    project => $root, type => 'ticket', title => 'Original title',
    description => 'Original body', priority => 3,
);
my $ref = $ticket->{ref};

my $created = $tira->history_list( project => $root, ref => $ref );
my %birth = map { $_->{field} => $_ } @{$created};
is( $birth{title}{op}, 'create', 'creation seeds an entry per set field' );
is( $birth{title}{after}, 'Original title', 'the birth value is recorded' );
is( $birth{title}{before}, undef, 'a birth entry has no previous value' );
is( $birth{priority}{after}, 3, 'numeric birth values are recorded' );
ok( !exists $birth{assignee}, 'unset fields are not seeded, so history stays sparse' );
is( $birth{title}{at}, '2026-08-07T12:00:00Z', 'entries carry the change time' );

$tick = '2026-08-07T12:05:00Z';
$tira->record_update( project => $root, ref => $ref, title => 'Second title', author => 'ada' );
my $after_update = $tira->history_list( project => $root, ref => $ref, field => 'title' );
is( scalar @{$after_update}, 2, 'field filtering returns only that field' );
my $edit = $after_update->[-1];
is( $edit->{op}, 'update', 'a field edit is an update' );
is( $edit->{before}, 'Original title', 'the previous value is preserved' );
is( $edit->{after}, 'Second title', 'the new value is recorded' );
is( $edit->{author}, 'ada', 'the supplied author is attributed' );
is( $edit->{ref}, $ref, 'entries name their record' );

$tick = '2026-08-07T12:10:00Z';
$tira->record_update( project => $root, ref => $ref, title => 'Third title' );
my $unattributed = $tira->history_list( project => $root, ref => $ref, field => 'title' )->[-1];
ok( !defined $unattributed->{author}, 'an unattributed change is recorded honestly, not guessed' );

eval { $tira->record_update( project => $root, ref => $ref, title => 'Nope', author => 'nobody' ) };
like( $@, qr/Unknown project person 'nobody'/, 'an unknown author is refused' );
is( $tira->record_show( project => $root, ref => $ref )->{title}, 'Third title',
    'a refused attribution leaves the record untouched' );

$tick = '2026-08-07T12:15:00Z';
$tira->column_add( project => $root, type => 'ticket', name => 'doing', label => 'Doing' );
$tira->record_move( project => $root, ref => $ref, column => 'doing', author => 'grace' );
my $moved = $tira->history_list( project => $root, ref => $ref, field => 'column' )->[-1];
is( $moved->{op}, 'move', 'a move is journaled even though it renames rather than rewrites' );
is( $moved->{before}, 'backlog', 'the previous column is recorded' );
is( $moved->{after}, 'doing', 'the new column is recorded' );
is( $moved->{author}, 'grace', 'moves carry their author' );

$tick = '2026-08-07T12:20:00Z';
$tira->comment_add( project => $root, ref => $ref, author => 'ada', text => 'A comment' );
my $structural = $tira->history_list( project => $root, ref => $ref, field => 'comments' )->[-1];
ok( $structural->{changed}, 'structural fields record that they changed' );
ok( !exists $structural->{after},
    'structural fields do not inline their whole value, keeping the journal small' );
is( $structural->{author}, 'ada', 'the comment author is attributed to the change' );

my $all = $tira->history_list( project => $root, ref => $ref );
my @stamps = map { $_->{at} } @{$all};
is_deeply( [@stamps], [ sort @stamps ], 'entries are stored oldest first' );

is( scalar @{ $tira->history_list( project => $root, ref => $ref, last => 1 ) }, 1,
    'last N windows the newest entries' );
is( $tira->history_list( project => $root, ref => $ref, last => 1 )->[0]{field}, 'comments',
    'the newest entry is the most recent change' );
is( $tira->history_list( project => $root, ref => $ref, first => 1 )->[0]{op}, 'create',
    'first N returns the oldest entries' );
is_deeply( $tira->history_list( project => $root, ref => $ref, count => 1 ),
    { count => scalar @{$all} }, 'count mode returns the total alone' );
is( scalar @{ $tira->history_list( project => $root, ref => $ref, since => '2026-08-07T12:12:00Z' ) },
    2, 'since filters by change time' );
is( scalar @{ $tira->history_list( project => $root, ref => $ref, where => ['op=move'] ) },
    1, 'where filters entries' );

eval { $tira->history_list( project => $root, ref => $ref, field => 'nosuchfield' ) };
like( $@, qr/Unknown field 'nosuchfield'/, 'an unknown field name fails loudly' );
eval { $tira->history_list( project => $root, ref => 'TKT-404' ) };
like( $@, qr/not found/, 'history for a missing record fails like any other read' );

my $fresh = $tira->create_record( project => $root, type => 'ticket', title => 'No edits yet' );
is_deeply( $tira->history_list( project => $root, ref => $fresh->{ref}, where => ['op=update'] ), [],
    'a record with no edits reports an explicit empty history' );

# History must never leak into the record, its hash, or the board scan.
my $stored = $tira->record_show( project => $root, ref => $ref );
ok( !exists $stored->{history}, 'the record itself carries no history field' );
my $hash_before = $tira->record_show( project => $root, ref => $ref, fields => ['content_hash'] )->{content_hash};
$tira->history_list( project => $root, ref => $ref );
is( $tira->record_show( project => $root, ref => $ref, fields => ['content_hash'] )->{content_hash},
    $hash_before, 'reading history never changes a content hash' );
is( $tira->export_records( project => $root, type => 'ticket' )->{count}, 2,
    'journal files are not mistaken for records by the board scan' );
ok( -f File::Spec->catfile( $root, '.tira', 'history', "$ref.jsonl" ),
    'history lives in its own append-only journal beside the boards' );

# A failed multi-record operation must not leave history claiming it happened.
my $before_failed = scalar @{ $tira->history_list( project => $root, ref => $ref ) };
eval { $tira->hierarchy_link( project => $root, parent => $ref, child => 'TKT-404' ) };
ok( $@, 'the invalid link fails' );
is( scalar @{ $tira->history_list( project => $root, ref => $ref ) }, $before_failed,
    'a rolled-back operation records no history' );

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
    'history.list', undef, '--project', $root, '--ref', $ref, '--field', 'title', '-o', 'json',
);
is( $status, 0, 'the CLI history command succeeds' );
my $payload = decode_json($out);
is( scalar @{$payload}, 3, 'the CLI returns the field timeline' );
is( $payload->[-1]{after}, 'Third title', 'the newest value is last' );

( $status, $out, $err ) = run_cli(
    'history.list', undef, '--project', $root, '--ref', $ref, '--count', '-o', 'json',
);
is( decode_json($out)->{count}, scalar @{$all} + 0, 'CLI count matches the engine' );

( $status, $out, $err ) = run_cli(
    'history.list', undef, '--project', $root, '--ref', $ref, '--field', 'nope', '-o', 'json',
);
is( $status, 2, 'an unknown CLI field exits 2' );
like( $err, qr/nope/, 'the error names the offending field' );

$tick = '2026-08-07T12:30:00Z';
$tira->record_update( project => $root, ref => $ref, description => ( 'L' x 3000 ) );
( $status, $out, $err ) = run_cli(
    'history.list', undef, '--project', $root, '--ref', $ref, '--field', 'description', '-o', 'json',
);
my $long = decode_json($out)->[-1];
is( length $long->{after}, 2001, 'long values truncate on read like every other long text' );
ok( $long->{after_truncated}, 'the truncation is marked' );
is( $long->{after_length}, 3000, 'the original length is reported' );

( $status, $out, $err ) = run_cli(
    'history.list', undef, '--project', $root, '--ref', $ref,
    '--field', 'description', '--full', '-o', 'json',
);
is( length decode_json($out)->[-1]{after}, 3000, '--full restores the complete value' );

done_testing;

__END__

=head1 NAME

39-history.t - per-field record history

=head1 DESCRIPTION

Proves the append-only per-record journal: creation seeds per-field birth
entries, edits record before and after with optional validated
attribution, moves are journaled despite renaming rather than rewriting,
structural fields record that they changed without inlining their value,
rolled-back operations record nothing, and reads support field filtering,
windows, since, where, count, and the standard truncation. Also proves
history never touches the record, its content hash, or the board scan.

=cut
