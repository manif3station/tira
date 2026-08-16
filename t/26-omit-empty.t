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
my $root = File::Spec->catdir( $tmp, 'sparse' );
my $tira = Tira->new( clock => sub { '2026-08-07T01:00:00Z' } );
$tira->create_project( name => 'Sparse', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
my $ticket = $tira->create_record(
    project => $root, type => 'ticket', title => 'Sparse card', priority => 3,
);
$tira->comment_add( project => $root, ref => $ticket->{ref}, author => 'ada', text => 'kept' );

my $pruned = $tira->record_show( project => $root, ref => $ticket->{ref}, omit_empty => 1 );
ok( !exists $pruned->{description}, 'an empty string field is omitted' );
ok( !exists $pruned->{labels}, 'an empty array field is omitted' );
ok( !exists $pruned->{assignee}, 'a null field is omitted' );
ok( !exists $pruned->{scope}, 'a hash of empty arrays is omitted' );
is( $pruned->{priority}, 3, 'a set value survives' );
is( $pruned->{title}, 'Sparse card', 'set text survives' );
is( scalar @{ $pruned->{comments} }, 1, 'populated arrays survive' );
is( $pruned->{ref}, $ticket->{ref}, 'ref always survives' );
is( $pruned->{column}, 'backlog', 'the computed column survives' );

my $full = $tira->record_show( project => $root, ref => $ticket->{ref} );
ok( exists $full->{description} && exists $full->{labels} && exists $full->{scope},
    'without omit_empty the full shape is unchanged' );

my $selected = $tira->record_show(
    project => $root, ref => $ticket->{ref}, omit_empty => 1, fields => ['sdlc_gate,priority'],
);
is_deeply( [ sort keys %{$selected} ], [qw(priority ref sdlc_gate)],
    'an explicitly selected field is exempt from empty-omission' );
ok( !defined $selected->{sdlc_gate}, 'the selected empty field is visibly null' );

my $exported = $tira->export_records( project => $root, omit_empty => 1 );
is( $exported->{count}, 1, 'the export envelope keeps its count' );
ok( !exists $exported->{records}[0]{evidence}, 'export prunes each record' );

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
    'record.show', 'ticket', '--ref', $ticket->{ref}, '-o', 'json',
);
is( $status, 0, 'CLI show succeeds' );
my $payload = decode_json($out);
ok( !exists $payload->{description} && !exists $payload->{labels},
    'the CLI omits empty fields by default' );
is( $payload->{priority}, 3, 'zero-adjacent set values are returned' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--ref', $ticket->{ref},
    '--include-empty', '-o', 'json',
);
is( $status, 0, 'CLI include-empty succeeds' );
$payload = decode_json($out);
ok( exists $payload->{description} && exists $payload->{labels} && exists $payload->{scope},
    '--include-empty restores the previous shape exactly' );

( $status, $out, $err ) = run_cli(
    'export', undef, '--include-empty', '-o', 'json',
);
is( $status, 0, 'export accepts include-empty' );
ok( exists decode_json($out)->{records}[0]{evidence}, 'export include-empty restores keys' );

( $status, $out, $err ) = run_cli(
    'record.update', 'ticket', '--ref', $ticket->{ref},
    '--title', 'Nope', '--include-empty', '-o', 'json',
);
is( $status, 2, 'include-empty on a mutation exits 2 instead of being ignored' );
like( $err, qr/show, list, and export/, 'the error explains where it applies' );

ok( !Tira::_is_empty_value( Cpanel::JSON::XS::false() ), 'boolean false is a value, never emptiness' );
ok( !Tira::_is_empty_value(0), 'zero is a value, never emptiness' );
ok( Tira::_is_empty_value( { nested => [], further => { deep => '' } } ), 'emptiness recurses through nested hashes' );

done_testing;

__END__

=head1 NAME

26-omit-empty.t - omit empty fields by default (CA15)

=head1 DESCRIPTION

Proves empty-value omission on the CLI read surface: null, empty-string,
empty-array, and recursively empty hash fields are omitted by default;
C<--include-empty> restores the full shape; explicitly selected fields
stay visible even when empty; set values including numerics always
survive; the export envelope is untouched; the engine only prunes when
asked, so internal callers are unaffected.

=cut
