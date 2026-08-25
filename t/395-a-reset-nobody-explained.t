#!/usr/bin/env perl
# zen-framework's report (TKT-525): moving a card backward - all the way
# into Backlog, the most extreme case, since Backlog is always the
# structurally-first column - resets every already-done required item
# between the destination and the old position, per TKT-455's own design.
# That reset is correct and intended, but it happened silently: nothing on
# the card said WHY a required item that was done, with intact proof,
# suddenly reads as pending again. Michael's answer to Q-079: keep the
# reset (working as designed), but explain it - a comment on the card
# naming the structural backward move, so a reader is not left guessing
# whether someone undid real work.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Reset', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'documenting' ],
    sow_prefix => 'RST', epic_prefix => 'RSE', ticket_prefix => 'RSK',
);
$tira->column_update( project => $root, type => 'ticket', name => 'planning', required_action => ['P1'] );
$tira->column_update( project => $root, type => 'ticket', name => 'documenting', required_action => ['D1'] );

sub cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    return Tira::CLI->run( command => 'record.move', type => 'ticket', argv => \@argv );
}

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Round trip' );

sub mark_done {
    my ($item_name) = @_;
    my ($item) = grep { $_->{item} eq $item_name }
      @{ $tira->required_item_list( project => $root, ref => $card->{ref} ) };
    $tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref}, id => $item->{id},
        status => 'done', command => ['did it'], proof => ['done'] );
}

cli( '--ref', $card->{ref}, '--column', 'planning' );
mark_done('P1');
cli( '--ref', $card->{ref}, '--column', 'documenting' );
mark_done('D1');

is( scalar @{ $tira->record_show( project => $root, ref => $card->{ref} )->{comments} }, 0,
    'no explanatory comment exists yet - nothing backward has happened' );

# The exact repro shape: moving all the way back into Backlog.
cli( '--ref', $card->{ref}, '--column', 'backlog' );

my $after = $tira->record_show( project => $root, ref => $card->{ref} );
my ($item_p1) = grep { $_->{item} eq 'P1' } @{ $after->{required_items} };
my ($item_d1) = grep { $_->{item} eq 'D1' } @{ $after->{required_items} };
is( $item_p1->{status}, 'pending', 'P1 resets on the backward move, as TKT-455 already specified' );
is( $item_d1->{status}, 'pending', 'D1 resets too' );
ok( scalar @{ $item_p1->{proof} }, 'and P1 keeps its proof - the reset never touches it' );

is( scalar @{ $after->{comments} }, 1, 'exactly one explanatory comment was added, not one per reset item' );
my $explanation = $after->{comments}[0]{body};
like( $explanation, qr/backward/i, 'the comment names the move as backward' );
like( $explanation, qr/backlog/i, 'and names the destination' );
like( $explanation, qr/\bP1\b/, 'and lists which required item(s) reset' );
like( $explanation, qr/\bD1\b/, 'both of them' );
like( $explanation, qr/proof/i, 'and reassures a reader the proof itself was not touched' );

# A move that resets nothing (nothing was done yet) adds no comment - the
# explanation exists to cover a real reset, not to narrate every move.
my $quiet_card = $tira->create_record( project => $root, type => 'ticket', title => 'Never touched' );
cli( '--ref', $quiet_card->{ref}, '--column', 'planning' );
cli( '--ref', $quiet_card->{ref}, '--column', 'backlog' );
is( scalar @{ $tira->record_show( project => $root, ref => $quiet_card->{ref} )->{comments} }, 0,
    'a backward move that resets nothing (nothing was done) adds no comment' );

done_testing;

__END__

=head1 NAME

395-a-reset-nobody-explained.t - a backward-move reset explains itself on the card

=head1 DESCRIPTION

TKT-525: zen-framework reported moving a card into Backlog as silently
resetting every already-done required item, with intact proof suddenly
reading as pending. Reproduced and root-caused: Backlog is always the
structurally-first column, so a move into it is always the most extreme
case of TKT-455's existing, intended backward-reset design. Michael's
answer to Q-079: keep the reset, but add a comment explaining why - this
test confirms exactly one comment lands per reset (not one per item),
names the move as backward, names the destination, lists which items
reset, and reassures that proof was untouched; and that a backward move
resetting nothing adds no comment.

=cut
