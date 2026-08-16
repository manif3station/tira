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
my $tira = Tira->new( clock => sub { '2026-08-08T09:00:00Z' } );

sub run_cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => $command, argv => \@argv );
    return ( $status, $out, $err );
}

sub names {
    my ($root) = @_;
    return [ map { $_->{name} } @{ $tira->column_list( project => $root, type => 'ticket' ) } ];
}

my $root = File::Spec->catdir( $tmp, 'proj' );

# The board every command here works on, named the one way there is.
# TKT-250.
$ENV{TIRA_HOME} = $root;
$tira->project_new( name => 'Layout', dir => $root, columns => ['Backlog, Doing, Review'] );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'A card' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'review' );

# Applying what is already there changes nothing, and says so.
my $same = $tira->column_apply(
    project => $root, type => 'ticket',
    columns => [ map { { name => $_->{name} } } @{ $tira->column_list( project => $root, type => 'ticket' ) } ],
);
is_deeply( $same->{added}, [], 'applying the current layout adds nothing' );
is_deeply( $same->{removed}, [], 'and removes nothing' );
ok( !$same->{reordered}, 'and does not claim to have reordered' );
is_deeply( names($root), [qw(backlog doing review discard)], 'and the board is untouched' );

# Reorder, rename, threshold and watched, all in one call.
my $applied = $tira->column_apply(
    project => $root, type => 'ticket',
    columns => [
        { name => 'backlog' },
        { name => 'review', label => 'Reviewing', notify_after => 45 },
        { name => 'doing', watched => 0 },
        { name => 'discard' },
    ],
);
is_deeply( names($root), [qw(backlog review doing discard)], 'the order given is the order kept' );
ok( $applied->{reordered}, 'and the call reports that it reordered' );
my %column = map { $_->{name} => $_ } @{ $tira->column_list( project => $root, type => 'ticket' ) };
is( $column{review}{label}, 'Reviewing', 'a label is updated in the same call' );
is( $column{review}{notify_after}, 45, 'so is a threshold' );
is( $column{doing}{watched}, 0, 'and a watched flag' );
is( $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} )->{column},
    'review', 'and no card was moved by reordering' );

# Adding and removing in the same call.
$applied = $tira->column_apply(
    project => $root, type => 'ticket',
    columns => [
        { name => 'backlog' },
        { name => 'review' },
        { name => 'shipped', label => 'Shipped' },
        { name => 'discard' },
    ],
);
is_deeply( names($root), [qw(backlog review shipped discard)], 'one column is added and another removed' );
is_deeply( $applied->{added}, ['shipped'], 'the call reports what it added' );
is_deeply( $applied->{removed}, ['doing'], 'and what it removed' );

# Removing a column relocates its cards exactly as removing one at a time does.
my $stranded = $tira->create_record( project => $root, type => 'ticket', title => 'Stranded' );
$tira->record_move( project => $root, ref => $stranded->{ref}, column => 'shipped' );
$tira->column_apply(
    project => $root, type => 'ticket',
    columns => [ { name => 'backlog' }, { name => 'review' }, { name => 'discard' } ],
);
is( $tira->record_show( project => $root, type => 'ticket', ref => $stranded->{ref} )->{column},
    'discard', 'a card in a removed column lands in Discard, not lost' );

# Refusals, none of which may change anything.
my $before = names($root);
for my $case (
    [ [ { name => 'review' }, { name => 'discard' } ], qr/backlog/i, 'leaving out a protected column' ],
    [ [ { name => 'backlog' }, { name => 'review' } ], qr/discard/i, 'leaving out the discard column' ],
    [ [ { name => 'backlog' }, { name => 'review' }, { name => 'review' }, { name => 'discard' } ],
        qr/twice|duplicate/i, 'naming a column twice' ],
    [ [ { name => 'backlog' }, { name => '///' }, { name => 'discard' } ], qr/name/i, 'an invalid name' ],
    [ [ { name => 'backlog' }, { name => 'review', notify_after => 0 }, { name => 'discard' } ],
        qr/notify/i, 'a threshold of zero' ],
    [ [], qr/column/i, 'an empty layout' ],
) {
    my ( $columns, $error, $label ) = @{$case};
    eval { $tira->column_apply( project => $root, type => 'ticket', columns => $columns ) };
    like( $@, $error, "$label is refused" );
    is_deeply( names($root), $before, "$label changes nothing" );
}

# The CLI takes the layout as JSON, which is what the browser will send.
my ( $status, $out ) = run_cli( 'column.apply', '--type', 'ticket',
    '--columns-json', encode_json( [ { name => 'backlog' }, { name => 'review' },
        { name => 'ready', label => 'Ready' }, { name => 'discard' } ] ),
    '-o', 'json' );
is( $status, 0, 'the CLI applies a layout' );
is_deeply( decode_json($out)->{added}, ['ready'], 'and reports what changed' );
is_deeply( names($root), [qw(backlog review ready discard)], 'and the board matches' );

( $status, $out ) = run_cli( 'column.apply', '--type', 'ticket',
    '--columns-json', 'not json', '-o', 'json' );
is( $status, 2, 'a layout that is not JSON exits 2' );

# A folder made for a new column must be taken back if the write then fails.
{
    no warnings 'redefine';
    local *Tira::_write_yaml = sub { die "disk full\n" };
    eval {
        $tira->column_apply(
            project => $root, type => 'ticket',
            columns => [ { name => 'backlog' }, { name => 'review' }, { name => 'ready' },
                { name => 'nowhere' }, { name => 'discard' } ],
        );
    };
    like( $@, qr/disk full/, 'a failed write is reported rather than swallowed' );
}
ok( !-d File::Spec->catdir( $root, '.tira', 'ticket', 'nowhere' ),
    'and the folder it had already made is taken back' );
is_deeply( names($root), [qw(backlog review ready discard)], 'leaving the board as it was' );

( $status, $out ) = run_cli( 'column.apply', '--help' );
is( $status, 0, 'the command offers help' );
like( $out, qr/Usage/i,
    'and prints some, so the denial below is about help that exists' );
unlike( $out, qr/--project|TIRA_HOME/, 'help never discloses project selection' );

( $status, $out ) = run_cli( 'ticket.list', '--columns-json', '[]', '-o', 'json' );
is( $status, 2, 'the layout option is refused on commands it does not belong to' );

done_testing;

__END__

=head1 NAME

52-column-apply.t - applying a whole column layout in one call

=head1 DESCRIPTION

A drag-reorder editor knows the layout it wants, not the sequence of
steps that reaches it. Proves that one call takes the desired list and
works out the difference: what to add, what to remove, what order to
sit in, and which labels, thresholds and watched flags to carry. Cards
in a removed column are relocated exactly as removing one at a time
would relocate them, a protected column left out is refused, and every
refusal leaves the board exactly as it was.

=cut
