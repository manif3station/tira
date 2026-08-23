#!/usr/bin/env perl
# tira.board.show reports a board's column CONFIGURATION - label, name,
# protected, queue, watched - and never how much is in it. The board
# already knows every one of those numbers: it knows its columns, and it
# knows every card's column. TKT-394.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-23T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Counted', dir => $root, members => ['claude'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'CTS', epic_prefix => 'CTE', ticket_prefix => 'CTT',
);

sub card {
    my (%args) = @_;
    return $tira->create_record( project => $root, type => 'ticket', %args );
}

my $before = $tira->board_show( project => $root, type => 'ticket' );

# --- a known distribution, not an empty board where zero passes either way --

card( title => 'One' );
card( title => 'Two' );
my $moved = card( title => 'Three' );
$tira->record_move( author => 'claude', project => $root, ref => $moved->{ref}, column => 'implement' );

my $after = $tira->board_show( project => $root, type => 'ticket' );

my %by_name = map { $_->{name} => $_ } @{ $after->{columns} };
is( $by_name{backlog}{count}, 2, 'backlog reports the two cards sitting in it' );
is( $by_name{implement}{count}, 1, 'and implement reports the one that moved there' );
is( $by_name{verify}{count}, 0, 'a column with nothing in it reports zero, not an absent key' );

# --- the existing configuration fields are byte-identical to today's --------

for my $name ( keys %by_name ) {
    my %without_count = %{ $by_name{$name} };
    delete $without_count{count};
    my ($original) = grep { $_->{name} eq $name } @{ $before->{columns} };
    my %original_without_count = %{$original};
    delete $original_without_count{count};
    is_deeply( \%without_count, \%original_without_count,
        "column '$name' keeps every field it had before, unchanged" );
}
is_deeply( [ sort keys %$before ], [ sort keys %$after ],
    'and every top-level key board.show already had is still there' )
  or note explain( [ $before, $after ] );

# --- the count is read, not stored ------------------------------------------

my $config_path = File::Spec->catdir( $root, '.tira', 'ticket', 'config.yml' );
open my $fh, '<', $config_path or die $!;
my $raw = do { local $/; <$fh> };
close $fh;
like( $raw, qr/name:\s*backlog/, 'the file was actually read - not an empty denial' );
unlike( $raw, qr/count/, "config.yml itself never learns a count - board.show is not a second writer" );

done_testing;

__END__

=head1 NAME

355-a-board-that-cannot-say-how-full-it-is.t - board.show reports a count per column

=head1 DESCRIPTION

C<tira.board.show> answered only a board's column configuration, never how
much work sits where - answering that meant dumping every card and
aggregating by hand. This proves a known distribution of cards is reported
correctly per column including a genuine zero, that every existing
configuration field is unchanged, and that the count is computed from the
card list rather than written into the column configuration file itself.

=cut
