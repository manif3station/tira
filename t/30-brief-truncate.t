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
my $root = File::Spec->catdir( $tmp, 'condensed' );
my $tira = Tira->new( clock => sub { '2026-08-07T06:00:00Z' } );
$tira->create_project( name => 'Condensed', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );

my $long_title = 'T' x 100;
my $long_body = 'D' x 2500;
my $ticket = $tira->create_record(
    project => $root, type => 'ticket', title => $long_title, description => $long_body,
);
my $ref = $ticket->{ref};
$tira->gate_add(
    project => $root, ref => $ref, gate => 'G1', result => 'pass',
    details => ( 'G' x 300 ), author => 'ada',
);

my $brief = $tira->record_show( project => $root, ref => $ref, brief => 1 );
is_deeply( [ sort keys %{$brief} ], [qw(assignee column ref sdlc_gate title)],
    'brief is exactly the documented five fields' );
ok( exists $brief->{assignee} && !defined $brief->{assignee},
    'a null assignee stays visible in brief output' );
is( length $brief->{title}, 73, 'the brief title is cut at 72 characters plus the ellipsis' );
is( substr( $brief->{title}, -1 ), "\x{2026}", 'the brief truncation is visibly marked' );

eval { $tira->record_show( project => $root, ref => $ref, brief => 1, fields => ['column'] ) };
like( $@, qr/Brief contradicts an explicit field selection/, 'brief with fields fails rather than guessing' );

my $trimmed = $tira->record_show( project => $root, ref => $ref, truncate => 100 );
is( length $trimmed->{description}, 101, 'a long field is cut at the limit plus the ellipsis' );
ok( $trimmed->{description_truncated}, 'the truncation is marked, never silent' );
is( $trimmed->{description_length}, 2500, 'the original length is reported' );
is( $trimmed->{title}, $long_title, 'the title is not a long-text field and stays whole' );
my ($gate_entry) = @{ $trimmed->{gate_passing_log} };
is( length $gate_entry->{details}, 101, 'gate log details truncate per entry' );
ok( $gate_entry->{details_truncated}, 'the entry carries its own marker' );
is( $gate_entry->{details_length}, 300, 'the entry reports its original length' );

my $short = $tira->create_record( project => $root, type => 'ticket', title => 'Short', description => 'brief note' );
my $untouched = $tira->record_show( project => $root, ref => $short->{ref}, truncate => 100 );
is( $untouched->{description}, 'brief note', 'short fields return whole' );
ok( !exists $untouched->{description_truncated}, 'no marker noise on small records' );

my $omitted = $tira->record_show( project => $root, ref => $ref, truncate => 0 );
ok( !exists $omitted->{description}, 'truncate zero omits the field entirely' );
ok( $omitted->{description_truncated}, 'the omitted field is still marked present' );
is( $omitted->{description_length}, 2500, 'the omitted field still reports its length' );

my $selected = $tira->record_show( project => $root, ref => $ref, truncate => 100, fields => ['description'] );
ok( $selected->{description_truncated}, 'truncation markers ride along with a selected field' );

my $hash_full = $tira->record_show( project => $root, ref => $ref, fields => ['content_hash'] )->{content_hash};
my $hash_trimmed = $tira->record_show(
    project => $root, ref => $ref, truncate => 50, fields => ['content_hash'],
)->{content_hash};
is( $hash_trimmed, $hash_full, 'truncation is presentation only: the content hash is unmoved' );

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
    'record.show', 'ticket', '--project', $root, '--ref', $ref, '-o', 'json',
);
my $payload = decode_json($out);
is( length $payload->{description}, 2001, 'the CLI truncates long text at 2000 by default' );
ok( $payload->{description_truncated}, 'the CLI default truncation is marked' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root, '--ref', $ref, '--full', '-o', 'json',
);
$payload = decode_json($out);
is( length $payload->{description}, 2500, '--full restores the complete value' );
ok( !exists $payload->{description_truncated}, '--full carries no markers' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root, '--ref', $ref, '--truncate', '100', '-o', 'json',
);
is( length decode_json($out)->{description}, 101, 'a caller-chosen limit applies' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root, '--ref', $ref,
    '--truncate', '100', '--full', '-o', 'json',
);
is( $status, 2, 'full and truncate together exit 2' );
like( $err, qr/--full with --truncate/, 'the contradiction is named' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root, '--ref', $ref, '--truncate', '-5', '-o', 'json',
);
is( $status, 2, 'a negative limit exits 2' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root, '--ref', $ref, '--brief', '-o', 'json',
);
$payload = decode_json($out);
is_deeply( [ sort keys %{$payload} ], [qw(assignee column ref sdlc_gate title)],
    'CLI brief returns the documented preset' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root, '--ref', $ref,
    '--brief', '--fields', 'column', '-o', 'json',
);
is( $status, 2, 'brief with fields exits 2' );

( $status, $out, $err ) = run_cli(
    'record.update', 'ticket', '--project', $root, '--ref', $ref,
    '--title', 'Nope', '--brief', '-o', 'json',
);
is( $status, 2, 'brief on a mutation exits 2' );
like( $err, qr/show, list, and export/, 'the error explains where brief applies' );

done_testing;

__END__

=head1 NAME

30-brief-truncate.t - brief preset and long-text truncation (CA08, CA09)

=head1 DESCRIPTION

Proves the five-field C<--brief> preset (null assignee visible, title cut
at a documented 72 characters with an ellipsis, contradiction with
C<--fields> loud) and default long-text truncation (2000 characters with
per-field and per-entry markers and original lengths, C<--full> restoring
everything, C<--truncate N> caller-chosen, zero omitting but marking,
short fields untouched, and the content hash unaffected because
truncation is presentation only).

=cut
