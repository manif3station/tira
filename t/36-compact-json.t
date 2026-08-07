#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Encode qw(encode_utf8);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'dense' );
my $tira = Tira->new( clock => sub { '2026-08-07T13:00:00Z' } );
$tira->create_project( name => 'Dense', dir => $root );
my $ticket = $tira->create_record(
    project => $root, type => 'ticket', title => "Costs \x{A3}9", priority => 2,
);

my $record = $tira->record_show( project => $root, ref => $ticket->{ref} );
my $compact = $tira->format_output( $record, output => 'json' );
my $pretty = $tira->format_output( $record, output => 'json-pretty' );

unlike( $compact, qr/\n./s, 'compact JSON is one line plus a trailing newline' );
like( $pretty, qr/\n\s+"/, 'json-pretty keeps the indented shape' );
ok( length($compact) < length($pretty), 'the compact form is measurably smaller on the same data' );
is_deeply( decode_json( encode_utf8($compact) ), decode_json( encode_utf8($pretty) ),
    'the two formats carry identical information' );
is( $compact, $tira->format_output( $record, output => 'json' ),
    'key order is stable across calls, so hashing and diffing work' );
like( $compact, qr/\x{A3}/, 'non-ASCII text is not escaped unnecessarily' );
unlike( $compact, qr/\\u00a3/i, 'no \\u escapes inflate the payload' );

eval { $tira->format_output( $record, output => 'yaml' ) };
like( $@, qr/Unsupported output format/, 'unknown formats still die' );

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
    'record.show', 'ticket', '--project', $root, '--ref', $ticket->{ref}, '-o', 'json',
);
is( $status, 0, 'CLI compact json succeeds' );
unlike( $out, qr/\n./s, 'the CLI default json is compact' );
is( decode_json($out)->{ref}, $ticket->{ref}, 'the compact payload parses' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root, '--ref', $ticket->{ref}, '-o', 'json-pretty',
);
is( $status, 0, 'json-pretty is available for humans' );
like( $out, qr/\n\s+"/, 'the pretty form is the previous shape' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root, '--ref', 'TKT-999', '-o', 'json',
);
is( $status, 2, 'a failing read exits 2' );
is( $out, '', 'stdout stays empty on failure so parsers never see corruption' );
like( $err, qr/TKT-999/, 'the structured error goes to stderr' );

done_testing;

__END__

=head1 NAME

36-compact-json.t - DD-435 compact JSON by default (CA14)

=head1 DESCRIPTION

Proves the default C<-o json> is compact with stable key order, raw
UTF-8, identical information to C<-o json-pretty> (today's shape,
explicitly requested), a measurable size win, and clean stdout/stderr
separation on failure.

=cut
