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
my $root = File::Spec->catdir( $tmp, 'tally' );
my $tira = Tira->new( clock => sub { '2026-08-07T05:00:00Z' } );
$tira->create_project( name => 'Tally', dir => $root );
my $one = $tira->create_record(
    project => $root, type => 'ticket', title => 'Alpha audio work',
    description => 'audio pipeline',
);
my $two = $tira->create_record( project => $root, type => 'ticket', title => 'Beta silent work' );
$tira->create_record( project => $root, type => 'epic', title => 'Gamma epic' );

is_deeply( $tira->record_list( project => $root, type => 'ticket', count => 1 ),
    { count => 2 }, 'count mode returns the number alone' );
is_deeply( $tira->record_list( project => $root, type => 'ticket', column => 'backlog', count => 1 ),
    { count => 2 }, 'count composes with filters' );
is_deeply( $tira->record_list( project => $root, type => 'ticket', column => 'discard', count => 1 ),
    { count => 0 }, 'zero is an answer, not a failure' );

is_deeply( $tira->record_list( project => $root, type => 'ticket', refs_only => 1 ),
    [ $one->{ref}, $two->{ref} ], 'refs-only returns the stable ref-ordered list' );
is_deeply( $tira->record_list( project => $root, type => 'ticket', column => 'discard', refs_only => 1 ),
    [], 'an empty refs result is an empty array, not null' );

is_deeply(
    $tira->record_list( project => $root, type => 'ticket', count => 1, refs_only => 1, fields => ['column'] ),
    { count => 2 }, 'count wins over refs-only and projection, as documented' );
eval { $tira->record_list( project => $root, type => 'ticket', count => 1, fields => ['nosuchfield'] ) };
like( $@, qr/Unknown field 'nosuchfield'/, 'count mode still validates field names loudly' );

is_deeply( $tira->export_records( project => $root, count => 1 ),
    { count => 3 }, 'export count is the whole board total' );

is_deeply( $tira->search( project => $root, text => 'audio', count => 1 ),
    { count => 1 }, 'search count suppresses the hits' );
is_deeply( $tira->search( project => $root, text => 'audio', refs_only => 1 ),
    [ $one->{ref} ], 'search refs-only returns matching refs' );
my $scoped = $tira->search(
    project => $root, text => 'a', type => 'ticket',
    fields => [ 'title', 'description' ], refs_only => 1,
);
is_deeply( $scoped, [ $one->{ref}, $two->{ref} ],
    'field-scoped search refs deduplicate multi-field hits into unique refs' );
is_deeply( $tira->search( project => $root, text => 'a', fields => ['title'], count => 1 ),
    { count => 3 }, 'field-scoped search count counts hits' );

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
    'record.list', 'ticket', '--count', '-o', 'json',
);
is( $status, 0, 'CLI count succeeds' );
is_deeply( decode_json($out), { count => 2 }, 'CLI count payload is the number alone' );

( $status, $out, $err ) = run_cli(
    'record.list', 'ticket', '--count', '-o', 'human',
);
is( $status, 0, 'human count succeeds' );
is( $out, "2\n", 'human count prints a bare number for the shell' );

( $status, $out, $err ) = run_cli(
    'record.list', 'ticket', '--refs-only', '-o', 'json',
);
is_deeply( decode_json($out), [ $one->{ref}, $two->{ref} ], 'CLI refs-only is a flat array' );

( $status, $out, $err ) = run_cli(
    'record.list', 'ticket', '--refs-only', '-o', 'human',
);
is( $out, "$one->{ref}\n$two->{ref}\n", 'human refs-only prints one ref per line' );

( $status, $out, $err ) = run_cli(
    'export', undef, '--count', '-o', 'json',
);
is_deeply( decode_json($out), { count => 3 }, 'CLI export count is the board total' );

( $status, $out, $err ) = run_cli(
    'search', undef, '--text', 'audio', '--count', '-o', 'json',
);
is_deeply( decode_json($out), { count => 1 }, 'CLI search count works' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--ref', $one->{ref}, '--count', '-o', 'json',
);
is( $status, 2, 'count on show exits 2' );
like( $err, qr/list, export, and search/, 'the count error names where it applies' );

( $status, $out, $err ) = run_cli(
    'export', undef, '--refs-only', '-o', 'json',
);
is( $status, 2, 'refs-only on export exits 2' );
like( $err, qr/list and search/, 'the refs-only error names where it applies' );

done_testing;

__END__

=head1 NAME

29-count-refs.t - count-only and refs-only reads (CA07, CA17)

=head1 DESCRIPTION

Proves C<--count> on list, export, and search and C<--refs-only> on list
and search: bare envelopes, zero and empty answers, documented
precedence (count over refs-only over projection) with field validation
still loud, deduplicated search refs, shell-friendly human output, and
exit-2 refusal elsewhere.

=cut
