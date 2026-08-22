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

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'ledger' );
my $tick = '2026-08-07T12:00:00Z';
my $tira = Tira->new( clock => sub { $tick } );
$tira->create_project( name => 'Ledger', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Logged' );
my $ref = $ticket->{ref};

for my $round ( [ 'G1', 'pass' ], [ 'G2', 'fail' ], [ 'G3', 'pass' ] ) {
    $tick = '2026-08-07T12:0' . ( 1 + scalar( () = $round->[0] =~ /(\d)/ ) ) . ':00Z';
    $tira->gate_add(
        project => $root, ref => $ref, gate => $round->[0], result => $round->[1],
        details => 'Details for ' . $round->[0] . ( 'x' x 200 ), author => 'ada',
    );
}
$tira->gate_annotate(
    project => $root, ref => $ref, id => 'GATE-002', note => 'Was flaky infra', author => 'ada',
);
$tira->evidence_add( project => $root, ref => $ref, summary => 'First proof ' . ( 'e' x 150 ), author => 'ada' );
$tira->evidence_add( author => 'ada', project => $root, ref => $ref, summary => 'Second proof', uri => 'https://example.test/run' );

my $newest = $tira->gate_list( project => $root, ref => $ref, last => 1 );
is( scalar @{$newest}, 1, 'last 1 returns one gate entry' );
is( $newest->[0]{gate}, 'G3', 'the newest entry is last in storage order' );

is( scalar @{ $tira->gate_list( project => $root, ref => $ref, last => 9 ) },
    3, 'an oversize window returns everything' );
is_deeply( [ map { $_->{gate} } @{ $tira->gate_list( project => $root, ref => $ref, first => 2 ) } ],
    [ 'G1', 'G2' ], 'first N returns the earliest entries' );

is_deeply( $tira->gate_list( project => $root, ref => $ref, last => 0 ),
    { count => 3 }, 'a zero window reports the count' );
is_deeply( $tira->gate_list( project => $root, ref => $ref, count => 1 ),
    { count => 3 }, 'count mode matches' );

my $by_id = $tira->gate_list( project => $root, ref => $ref, id => 'GATE-002' );
is( $by_id->{gate}, 'G2', 'read-by-id returns the one entry' );
is( scalar @{ $by_id->{annotations} }, 1, 'annotations ride with their parent entry' );
eval { $tira->gate_list( project => $root, ref => $ref, id => 'GATE-999' ) };
like( $@, qr/GATE-999.*not found/, 'a missing id fails loudly' );

my $meta = $tira->gate_list( project => $root, ref => $ref, meta_only => 1 );
ok( !exists $meta->[0]{details}, 'meta-only omits the long details' );
is( $meta->[0]{details_length}, length( 'Details for G1' . ( 'x' x 200 ) ),
    'the details length is reported' );
is( $meta->[1]{annotation_count}, 1, 'the annotation count is included' );
is( $meta->[0]{result}, 'pass', 'results stay in the metadata' );

my $failures = $tira->gate_list( project => $root, ref => $ref, where => ['result=fail'] );
is_deeply( [ map { $_->{gate} } @{$failures} ], ['G2'], 'where filters entries: failures are what matter' );
is( scalar @{ $tira->gate_list( project => $root, ref => $ref, where => ['result!=fail'] ) },
    2, 'inequality works on entries' );
eval { $tira->gate_list( project => $root, ref => $ref, where => ['nosuchkey=1'] ) };
like( $@, qr/Unknown gate field 'nosuchkey'/, 'unknown entry fields fail naming the offender' );

my $latest_evidence = $tira->evidence_list( project => $root, ref => $ref, last => 1 );
is( $latest_evidence->[0]{summary}, 'Second proof', 'evidence windows mirror gates' );
my $evidence_meta = $tira->evidence_list( project => $root, ref => $ref, meta_only => 1 );
ok( !exists $evidence_meta->[0]{summary}, 'evidence meta omits the summary text' );
is( $evidence_meta->[0]{summary_length}, length( 'First proof ' . ( 'e' x 150 ) ),
    'the summary length is reported' );
is( $evidence_meta->[1]{uri}, 'https://example.test/run', 'the uri stays in evidence metadata' );
is_deeply( $tira->evidence_list( project => $root, ref => $ref, count => 1 ),
    { count => 2 }, 'evidence count mode works' );
my $by_evidence_id = $tira->evidence_list( project => $root, ref => $ref, id => 'EVD-002' );
is( $by_evidence_id->{summary}, 'Second proof', 'evidence read-by-id works' );

my $unchanged = $tira->gate_list( project => $root, ref => $ref );
is( scalar @{$unchanged}, 3, 'plain reads keep the full log exactly as before' );
ok( exists $unchanged->[0]{details}, 'plain reads keep the details' );

sub run_cli {
    my ( $command, $type, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run(
        command => $command, ( defined $type ? ( type => $type ) : () ), argv => \@argv,
    );
    return ( $status, $out, $err );
}

my ( $status, $out, $err ) = run_cli(
    'gate.list', undef, '--ref', $ref, '--last', '1', '-o', 'json',
);
is( $status, 0, 'CLI gate window succeeds' );
is( decode_json($out)->[0]{gate}, 'G3', 'the CLI returns the newest gate entry' );

( $status, $out, $err ) = run_cli(
    'gate.list', undef, '--ref', $ref,
    '--where', 'result=fail', '--meta-only', '-o', 'json',
);
my $payload = decode_json($out);
is( scalar @{$payload}, 1, 'CLI where composes with meta-only on entries' );
ok( !exists $payload->[0]{details}, 'the composed result is metadata' );

( $status, $out, $err ) = run_cli(
    'evidence.list', undef, '--ref', $ref, '--id', 'EVD-001', '-o', 'json',
);
is( decode_json($out)->{summary}, 'First proof ' . ( 'e' x 150 ), 'CLI evidence read-by-id works' );

( $status, $out, $err ) = run_cli(
    'checklist.list', undef, '--ref', $ref, '--last', '1', '-o', 'json',
);
is( $status, 2, 'windows on the checklist exit 2: the scope is documented' );

done_testing;

__END__

=head1 NAME

35-log-windows.t - indexed gate log and evidence reads (CA20)

=head1 DESCRIPTION

Proves C<--last>/C<--first> windows, zero-window and count modes,
read-by-id with loud misses, C<--meta-only> (lengths and annotation
counts, results and uris retained), and C<--where> entry filtering on
both append-only logs, with annotations riding their parent entries and
plain reads unchanged.

=cut
