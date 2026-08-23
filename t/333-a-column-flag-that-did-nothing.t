#!/usr/bin/env perl
# --column is the flag that names a column on record.move, record.list,
# notify.record and search - the reflex flag on this board. On the four
# commands that identify a COLUMN itself (column.add/update/rename/remove),
# the identifying flag is --name instead, and --column was silently accepted
# by option parsing and then ignored: column.update --column X --terminal
# updated nothing named by --column, and with --name absent entirely it died
# "Column '' not found" - a false, specific claim about the board when the
# real fault was a mistyped flag. TKT-305.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-23T05:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Columns', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'CLS', epic_prefix => 'CLE', ticket_prefix => 'CLT',
);

sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME}   = $root;
            local $ENV{TIRA_AUTHOR} = "claude";
            Tira::CLI->run( command => $command, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# --- --column alone, no --name, refuses naming --name rather than a lookup failure --

{
    my ( $status, $text ) = run( 'column.update', '--type', 'ticket', '--column', 'implement', '--terminal' );
    isnt( $status, 0, 'column.update with only --column, no --name, is refused' );
    like( $text, qr/--name/, 'and the refusal names --name as the correct flag' );
    unlike( $text, qr/not found/, 'and it is not reported as a lookup failure on an empty name' );
}

# --- --name present but --column also given: refused, not silently ignored ---------

{
    my ( $status, $text ) = run(
        'column.update', '--type', 'ticket', '--name', 'implement', '--column', 'bogus', '--terminal'
    );
    isnt( $status, 0, 'column.update with --name AND a stray --column is refused' );
    like( $text, qr/--name/, 'naming --name as the one to use' );

    my ($column) = grep { $_->{name} eq 'implement' } @{ $tira->column_list( project => $root, type => 'ticket' ) };
    ok( !$column->{terminal}, 'and the update did not silently apply despite the refusal' );
}

# --- the same refusal on the other three column-identifying commands ---------------

for my $case (
    [ 'column.add',    [ '--type', 'ticket', '--column', 'x', '--name', 'newcol' ] ],
    [ 'column.rename',  [ '--type', 'ticket', '--column', 'x', '--name', 'implement', '--new-name', 'doing' ] ],
    [ 'column.remove', [ '--type', 'ticket', '--column', 'x', '--name', 'implement' ] ],
) {
    my ( $command, $argv ) = @{$case};
    my ( $status, $text ) = run( $command, @{$argv} );
    isnt( $status, 0, "$command with a stray --column is refused" );
    like( $text, qr/--name/, "${command}'s refusal also names --name" );
}

# --- --column is unaffected everywhere it already means something ------------------

{
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Unaffected' );
    my ( $status, $text ) = run( 'record.move', '--ref', $card->{ref}, '--column', 'implement' );
    is( $status, 0, '--column still works, unchanged, on record.move' );

    ( $status, $text ) = run( 'record.list', '--column', 'implement', '-o', 'json' );
    is( $status, 0, '--column still works, unchanged, on record.list' );
}

done_testing;

__END__

=head1 NAME

333-a-column-flag-that-did-nothing.t - column.add/update/rename/remove refuse a stray --column

=head1 DESCRIPTION

C<--column> is the flag that names a column on C<record.move>,
C<record.list>, C<notify.record> and C<search>. On the four commands that
identify a column itself - C<column.add>, C<column.update>,
C<column.rename>, C<column.remove> - the identifying flag is C<--name>
instead, and C<--column> was silently accepted by option parsing and then
ignored, producing a misleading "not found" for an empty name rather than a
usage error naming the actual mistake. All four now refuse a stray
C<--column>, naming C<--name>. TKT-305.

=cut
