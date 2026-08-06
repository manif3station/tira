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
my $root = File::Spec->catdir( $tmp, 'sieve' );
my $tira = Tira->new( clock => sub { '2026-08-07T08:00:00Z' } );
$tira->create_project( name => 'Sieve', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
my $gated = $tira->create_record(
    project => $root, type => 'ticket', title => 'Gated work',
    sdlc_gate => 'G13', assignee => 'ada', priority => 5, labels => ['Zenandi-Developer'],
);
my $parked = $tira->create_record( project => $root, type => 'ticket', title => 'Parked work' );
my $epic = $tira->create_record( project => $root, type => 'epic', title => 'Owner epic' );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $gated->{ref} );

my $where = sub { $tira->record_list( project => $root, type => 'ticket', where => [@_] ) };

is_deeply( [ map { $_->{ref} } @{ $where->('sdlc_gate=G13') } ],
    [ $gated->{ref} ], 'equality filters on any scalar field' );
is_deeply( [ map { $_->{ref} } @{ $where->('sdlc_gate=') } ],
    [ $parked->{ref} ], 'an empty value means the field is empty or unset' );
is_deeply( [ map { $_->{ref} } @{ $where->('sdlc_gate!=G13') } ],
    [ $parked->{ref} ], 'inequality excludes the value' );
is_deeply( [ map { $_->{ref} } @{ $where->('sdlc_gate!=') } ],
    [ $gated->{ref} ], 'inequality against empty means the field has a value' );
is_deeply( [ map { $_->{ref} } @{ $where->( 'column=backlog', 'sdlc_gate=' ) } ],
    [ $parked->{ref} ], 'repeated clauses combine with AND' );
is_deeply( [ map { $_->{ref} } @{ $where->('labels~zenandi-developer') } ],
    [ $gated->{ref} ], 'containment matches array elements case-insensitively' );
is_deeply( $where->('title~anything'), [], 'containment on a non-array field matches nothing rather than crashing' );
is_deeply( [ map { $_->{ref} } @{ $where->('priority=5') } ],
    [ $gated->{ref} ], 'numeric equality compares by value string' );
is_deeply( [ map { $_->{ref} } @{ $where->( 'parent=' . $epic->{ref} ) } ],
    [ $gated->{ref} ], 'parent filtering no longer needs a full export' );
is_deeply( [ map { $_->{ref} } @{ $where->('attachment_count=0') } ],
    [ $gated->{ref}, $parked->{ref} ], 'computed fields are filterable' );

my $projected = $tira->record_list(
    project => $root, type => 'ticket', where => ['sdlc_gate=G13'], fields => ['column'],
);
is_deeply( [ sort keys %{ $projected->[0] } ], [qw(column ref)], 'where composes with projection' );
is_deeply( $tira->record_list( project => $root, type => 'ticket', where => ['sdlc_gate='], count => 1 ),
    { count => 1 }, 'where composes with count' );

eval { $where->('nosuchfield=1') };
like( $@, qr/Unknown field 'nosuchfield'/, 'an unknown where field fails loudly' );
eval { $where->('justtext') };
like( $@, qr/FIELD=VALUE/, 'a clause without an operator names the accepted forms' );

my $exported = $tira->export_records( project => $root, where => ['column=backlog'] );
is( $exported->{count}, 3, 'export accepts where across all types' );

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
    'record.list', 'ticket', '--project', $root,
    '--where', 'column=backlog', '--where', 'sdlc_gate=', '-o', 'json',
);
is( $status, 0, 'CLI where succeeds' );
my $payload = decode_json($out);
is( scalar @{$payload}, 1, 'the CLI applies every clause' );
is( $payload->[0]{ref}, $parked->{ref}, 'the parked ticket is the match' );

( $status, $out, $err ) = run_cli(
    'record.list', 'ticket', '--project', $root,
    '--where', 'sdlc_gate=', '--count', '-o', 'json',
);
is_deeply( decode_json($out), { count => 1 }, 'CLI where composes with count' );

( $status, $out, $err ) = run_cli(
    'record.list', 'ticket', '--project', $root, '--where', 'nosuchfield=1', '-o', 'json',
);
is( $status, 2, 'an unknown CLI where field exits 2' );
like( $err, qr/nosuchfield/, 'the error names the field' );

( $status, $out, $err ) = run_cli(
    'record.update', 'ticket', '--project', $root, '--ref', $gated->{ref},
    '--title', 'Nope', '--where', 'column=backlog', '-o', 'json',
);
is( $status, 2, 'where on a mutation exits 2' );
like( $err, qr/list and export/, 'the error names where filtering applies' );

done_testing;

__END__

=head1 NAME

32-where.t - DD-431 server-side field filtering (CA16)

=head1 DESCRIPTION

Proves repeatable ANDed C<--where> clauses on list and export: scalar
equality, empty-as-absence (CA15 emptiness rule), inequality both ways,
case-insensitive array containment that cannot crash on scalars,
computed-field filtering, composition with projection and count, and
loud failures for unknown fields and operatorless clauses.

=cut
