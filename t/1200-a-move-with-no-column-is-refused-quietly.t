#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

# TKT-1200. record.move with no --column reaches three `exists $index{ $args{column} }`
# lookups in Tira::CLI::Move with an undef column, so Perl printed "Use of
# uninitialized value $args{"column"} in exists" three times (lines 70, 300, 470)
# before the slug check finally refused with "Invalid column name" - a message that
# says the NAME is invalid when the option was simply not given.
#
# What is held here: the refusal is one clear line that names the missing --column
# option, no Perl warning is printed, the card is left exactly as it was, and a move
# that does give --column still lands.

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-30T02:30:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Quiet', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'QS', epic_prefix => 'QE', ticket_prefix => 'QT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card that must not move without a column', priority => 3 );

sub move {
    my (@argv) = @_;
    my ( $out, $err, @warnings ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        local $SIG{__WARN__} = sub { push @warnings, $_[0]; print {$se} $_[0] };
        Tira::CLI->run( command => 'record.move', type => 'ticket', tira => $tira,
            argv => [ '--ref', $card->{ref}, '--author', 'claude', @argv ] );
    };
    return ( $status, $out . $err, \@warnings );
}

sub snapshot {
    my $record = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    return { column => $record->{column}, comments => scalar @{ $record->{comments} || [] },
             log => scalar @{ $record->{gate_passing_log} || [] } };
}

# --- no --column at all -----------------------------------------------------

{
    my $before = snapshot();
    my ( $status, $said, $warnings ) = move();
    isnt( $status, 0, 'a move with no --column is refused' );
    is_deeply( $warnings, [], 'and prints no Perl warning at all' );
    like( $said, qr/--column/, 'the refusal names the option that is missing' );
    like( $said, qr/\b(?:required|missing|must be given|not given)\b/i, 'and says it is missing, not that a name is invalid' );
    unlike( $said, qr/Invalid column name/, 'it does not blame a column name nobody gave' );
    is( scalar( () = $said =~ /^\S/mg ), 1, 'and is exactly one line' );
    is_deeply( snapshot(), $before, 'the card is exactly as it was' );
}

# --- an empty --column is the same mistake ----------------------------------

{
    my $before = snapshot();
    my ( $status, $said, $warnings ) = move( '--column', '' );
    isnt( $status, 0, 'an empty --column is refused' );
    is_deeply( $warnings, [], 'without a Perl warning' );
    unlike( $said, qr/uninitialized/, 'and without an uninitialized-value message' );
    is_deeply( snapshot(), $before, 'and leaves the card alone' );
}

# --- control: a move that gives --column still lands ------------------------

{
    my ( $status, undef, $warnings ) = move( '--column', 'implement' );
    is( $status, 0, 'a move that gives --column still succeeds' );
    is_deeply( $warnings, [], 'quietly' );
    is( snapshot()->{column}, 'implement', 'and the card is in the column it was sent to' );
}

done_testing;

__END__

=head1 NAME

1200-a-move-with-no-column-is-refused-quietly.t - a move with no --column is refused once, in words, with no Perl warning

=head1 DESCRIPTION

TKT-1200. C<record.move> with no C<--column> reached three C<exists> lookups in
C<Tira::CLI::Move> with an undefined column, printing C<Use of uninitialized value>
three times before the slug check refused with C<Invalid column name>, a message
that blames a name nobody gave. This file holds that the refusal is a single line
naming the missing C<--column> option, that no Perl warning is printed, that an
empty C<--column> is treated the same way, that the card is untouched, and, as a
control, that a move which does give C<--column> still lands.

=cut
