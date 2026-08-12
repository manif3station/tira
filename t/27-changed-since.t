#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json encode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'delta' );
my $tick = '2026-08-07T01:00:00Z';
my $tira = Tira->new( clock => sub { $tick } );
$tira->create_project( name => 'Delta', dir => $root );

my $early = $tira->create_record( project => $root, type => 'ticket', title => 'Early card' );
$tick = '2026-08-07T02:00:00Z';
my $late = $tira->create_record( project => $root, type => 'ticket', title => 'Late card' );
$tick = '2026-08-07T03:00:00Z';
$tira->record_update( project => $root, ref => $early->{ref}, title => 'Early, revised' );

my $exported = $tira->export_records( project => $root, since => '2026-08-07T02:30:00Z' );
is( $exported->{count}, 1, 'only records changed at or after the threshold return' );
is( $exported->{records}[0]{ref}, $early->{ref}, 'the revised early record is the change' );
is( $exported->{now}, '2026-08-07T03:00:00Z', 'the envelope carries the server clock for chaining' );

$exported = $tira->export_records( project => $root, since => '2026-08-07T01:30:00Z' );
is( $exported->{count}, 2, 'an earlier threshold returns both records' );

$exported = $tira->export_records( project => $root, since => '2030-01-01T00:00:00Z' );
is_deeply( $exported->{records}, [], 'a future threshold returns empty rather than erroring' );
is( $exported->{count}, 0, 'the empty count is zero' );

my $offset = $tira->export_records( project => $root, since => '2026-08-07T03:30:00+01:00' );
is( $offset->{count}, 1, 'offsets compare by instant, not by string' );
is( $offset->{records}[0]{ref}, $early->{ref},
    'the 03:00Z record matches a 03:30+01:00 threshold, which string order would exclude' );

ok( !exists $tira->export_records( project => $root )->{now},
    'without since the export envelope is unchanged' );

my $listed = $tira->record_list(
    project => $root, type => 'ticket', since => '2026-08-07T02:30:00Z', fields => ['column'],
);
is( scalar @{$listed}, 1, 'list filtering composes with projection' );
is_deeply( [ sort keys %{ $listed->[0] } ], [qw(column ref)], 'the composed shape is projected' );

my $shown = $tira->record_show( project => $root, ref => $late->{ref}, since => '2026-08-07T02:30:00Z' );
is_deeply( $shown, {}, 'an unchanged record shows as an explicit empty object' );
$shown = $tira->record_show( project => $root, ref => $early->{ref}, since => '2026-08-07T02:30:00Z' );
is( $shown->{title}, 'Early, revised', 'a changed record shows in full' );

eval { $tira->export_records( project => $root, since => 'garbage' ) };
like( $@, qr/Since must be an ISO 8601 date-time/, 'a malformed threshold names the parse failure' );

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
    'export', undef, '--project', $root, '--since', '2026-08-07T02:30:00Z', '-o', 'json',
);
is( $status, 0, 'CLI since succeeds' );
my $payload = decode_json($out);
is( $payload->{count}, 1, 'the CLI filters by the threshold' );
like( $payload->{now}, qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/,
    'the CLI envelope carries the real server clock' );

( $status, $out, $err ) = run_cli(
    'export', undef, '--project', $root, '--since', '2030-01-01T00:00:00Z', '-o', 'json',
);
is( $status, 0, 'a future CLI threshold exits 0' );

( $status, $out, $err ) = run_cli(
    'export', undef, '--project', $root, '--since', 'garbage', '-o', 'json',
);
is( $status, 2, 'a malformed CLI threshold exits 2' );
like( $err, qr/ISO 8601/, 'the CLI error names the parse failure' );

my ( $late_path ) = glob "$root/.tira/ticket/*/$late->{ref}.json";
ok( $late_path, 'the late record file is locatable for the legacy-stamp check' );
( $late_path ) = $late_path =~ /\A(.+\.json)\z/s;
{
    open my $in, '<', $late_path or die $!;
    local $/; my $raw = <$in>; close $in;
    my $data = decode_json($raw);
    $data->{last_updated} = 'not-a-timestamp';
    open my $out, '>', $late_path or die $!;
    print {$out} encode_json($data);
    close $out;
}
$exported = $tira->export_records( project => $root, since => '2030-01-01T00:00:00Z' );
is( $exported->{count}, 1, 'a record with an unreadable stamp is never hidden by since' );
is( $exported->{records}[0]{ref}, $late->{ref}, 'the unreadable-stamp record is the one returned' );

( $status, $out, $err ) = run_cli(
    'record.update', 'ticket', '--project', $root, '--ref', $early->{ref},
    '--title', 'Nope', '--since', '2026-08-07T00:00:00Z', '-o', 'json',
);
is( $status, 2, 'since on a mutation exits 2 instead of being ignored' );
like( $err, qr/show, list, and export/, 'the error explains where since applies' );

done_testing;

__END__

=head1 NAME

27-changed-since.t - changed-since filtering (CA04)

=head1 DESCRIPTION

Proves C<--since> on show, list, and export: instant-based comparison
across timezone offsets, inclusive threshold, future thresholds empty
with exit 0, malformed thresholds loud with exit 2, envelope C<now> for
gap-free chaining, unreadable legacy stamps never hidden, and
composition with field projection.

=cut
