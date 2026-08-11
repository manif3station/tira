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
my $root = File::Spec->catdir( $tmp, 'delta2' );
my $tick = '2026-08-07T10:00:00Z';
my $tira = Tira->new( clock => sub { $tick } );
$tira->create_project( name => 'Delta2', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
my $steady = $tira->create_record( project => $root, type => 'ticket', title => 'Steady' );
my $mover = $tira->create_record( project => $root, type => 'ticket', title => 'Mover', sdlc_gate => 'G1' );
$tira->column_add( project => $root, type => 'ticket', name => 'doing', label => 'Doing' );

my $snapshot_path = File::Spec->catfile( $tmp, 'state.json' );
open my $snap, '>:raw', $snapshot_path or die $!;
print {$snap} JSON::PP->new->encode( $tira->export_records( project => $root ) );
close $snap;

$tick = '2026-08-07T11:00:00Z';
$tira->record_move( project => $root, ref => $mover->{ref}, column => 'doing' );
$tira->record_update( project => $root, ref => $mover->{ref}, sdlc_gate => 'G2' );
my $comment = $tira->comment_add( project => $root, ref => $mover->{ref}, author => 'ada', text => 'Moved on' );
my $fresh = $tira->create_record( project => $root, type => 'ticket', title => 'Fresh arrival' );

my $diff = $tira->diff_records( project => $root, since => '2026-08-07T10:30:00Z' );
is( $diff->{now}, '2026-08-07T11:00:00Z', 'the diff carries now for chaining' );
is( $diff->{count}, 2, 'only records changed since the threshold appear' );
my %by_ref = map { $_->{ref} => $_ } @{ $diff->{changes} };
is( $by_ref{ $fresh->{ref} }{kind}, 'added', 'a record created since the threshold is added' );
is( $by_ref{ $mover->{ref} }{kind}, 'changed', 'an older record is changed' );
is( $by_ref{ $mover->{ref} }{column}, 'doing', 'the current column is included for acting without a re-read' );
is( $by_ref{ $mover->{ref} }{sdlc_gate}, 'G2', 'the current gate is included' );
is_deeply( $by_ref{ $mover->{ref} }{new_comments}, [ $comment->{id} ],
    'new comment ids are listed' );

my $quiet = $tira->diff_records( project => $root, since => '2030-01-01T00:00:00Z' );
is_deeply( $quiet->{changes}, [], 'an empty diff is an explicit empty result, not silence' );
is( $quiet->{count}, 0, 'the empty diff counts zero' );

is_deeply( $tira->diff_records( project => $root, since => '2026-08-07T10:30:00Z', count => 1 ),
    { count => 2 }, 'diff count mode answers whether to look' );

my $snapshot_diff = $tira->diff_records( project => $root, snapshot => $snapshot_path );
%by_ref = map { $_->{ref} => $_ } @{ $snapshot_diff->{changes} };
is( $by_ref{ $fresh->{ref} }{kind}, 'added', 'snapshot mode reports additions' );
my ($column_change) = grep { $_->{field} eq 'column' } @{ $by_ref{ $mover->{ref} }{fields} };
is_deeply( [ $column_change->{before}, $column_change->{after} ], [ 'backlog', 'doing' ],
    'scalar changes carry before and after values' );
my ($gate_change) = grep { $_->{field} eq 'sdlc_gate' } @{ $by_ref{ $mover->{ref} }{fields} };
is_deeply( [ $gate_change->{before}, $gate_change->{after} ], [ 'G1', 'G2' ],
    'gate changes are first-class' );
my ($comment_change) = grep { $_->{field} eq 'comments' } @{ $by_ref{ $mover->{ref} }{fields} };
is_deeply( $comment_change->{added}, [ $comment->{id} ], 'snapshot mode names new comment ids' );
ok( !exists $by_ref{ $steady->{ref} }, 'an untouched record does not appear' );

my $scoped = $tira->diff_records(
    project => $root, snapshot => $snapshot_path, fields => ['column'],
);
%by_ref = map { $_->{ref} => $_ } @{ $scoped->{changes} };
is_deeply( [ map { $_->{field} } @{ $by_ref{ $mover->{ref} }{fields} } ], ['column'],
    'field scoping restricts the comparison to the named fields' );

my $structural_snapshot = File::Spec->catfile( $tmp, 'structural.json' );
open my $structural, '>:raw', $structural_snapshot or die $!;
print {$structural} JSON::PP->new->encode( $tira->export_records( project => $root ) );
close $structural;
$tira->record_update( project => $root, ref => $mover->{ref}, labels => ['sieved'] );
$tira->comment_update(
    project => $root, ref => $mover->{ref}, comment => $comment->{id}, text => 'Edited in place',
);
my $structural_diff = $tira->diff_records( project => $root, snapshot => $structural_snapshot );
my %structural_by_ref = map { $_->{ref} => $_ } @{ $structural_diff->{changes} };
my ($labels_change) = grep { $_->{field} eq 'labels' }
  @{ $structural_by_ref{ $mover->{ref} }{fields} };
ok( $labels_change->{changed}, 'a structural array change carries an explicit changed marker' );
my ($edited_comments) = grep { $_->{field} eq 'comments' }
  @{ $structural_by_ref{ $mover->{ref} }{fields} };
ok( $edited_comments->{changed} && !exists $edited_comments->{added},
    'an edited comment reports changed rather than pretending a new one arrived' );

my $removed_snapshot = File::Spec->catfile( $tmp, 'ghost.json' );
open my $ghost, '>:raw', $removed_snapshot or die $!;
print {$ghost} JSON::PP->new->encode( { records => [ { ref => 'TKT-777', type => 'ticket', title => 'Ghost' } ] } );
close $ghost;
my $ghost_diff = $tira->diff_records( project => $root, snapshot => $removed_snapshot );
my ($removal) = grep { $_->{kind} eq 'removed' } @{ $ghost_diff->{changes} };
is( $removal->{ref}, 'TKT-777', 'a deletion never looks like an absence of change' );

eval { $tira->diff_records( project => $root ) };
like( $@, qr/--since or --snapshot/, 'diff requires a baseline' );
eval { $tira->diff_records( project => $root, since => '2026-08-07T10:30:00Z', snapshot => $snapshot_path ) };
like( $@, qr/one of --since or --snapshot/, 'two baselines are refused' );

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
    'diff', undef, '--project', $root, '--since', '2026-08-07T10:30:00Z', '-o', 'json',
);
is( $status, 0, 'CLI diff succeeds' );
my $payload = decode_json($out);
is( $payload->{count}, 2, 'the CLI reports the change count' );

( $status, $out, $err ) = run_cli(
    'diff', undef, '--project', $root, '--snapshot', $snapshot_path, '--count', '-o', 'json',
);
is( decode_json($out)->{count}, 2, 'CLI snapshot diff composes with count' );

( $status, $out, $err ) = run_cli( 'diff', undef, '--project', $root, '-o', 'json' );
is( $status, 2, 'a baseline-less CLI diff exits 2' );

( $status, $out, $err ) = run_cli(
    'record.list', 'ticket', '--project', $root, '--snapshot', $snapshot_path, '-o', 'json',
);
is( $status, 2, 'snapshot outside diff exits 2' );
like( $err, qr/diff/, 'the error names the diff command' );

done_testing;

__END__

=head1 NAME

34-diff.t - first-class diff (CA13)

=head1 DESCRIPTION

Proves C<tira.diff> in both modes: since-based (added/changed kinds,
current column and gate for act-without-re-read, new comment ids, now
for chaining, explicit empty results, count mode) and snapshot-based
(per-field before/after for scalars, named new-comment ids, additions
and removals distinguished, field scoping), plus baseline validation and
CLI guards.

=cut
