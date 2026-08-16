#!/usr/bin/env perl
# A card is created in the column it was asked for.
#
# ticket.create accepted --column, understood it, and threw it away. The card
# landed in backlog, the command exited zero, and the whole record was printed
# as though the column had been honoured.
#
# Three projects hit it independently in one evening. developer-dashboard
# reproduced it twice back to back. mt5-ai adopted --column on create precisely
# to obey their owner's rule that a card is claimed into a working column before
# the work starts - and it silently did nothing for two cards whose own gate
# records then described them as having been populated "before leaving
# planning". Neither card was ever in planning.
#
# An unknown flag is refused loudly here: a misspelled field exits two and names
# the offender. So an accepted flag reads as an honoured flag, and that is what
# makes this worse than an outright error. It is the same shape as assign.set
# taking --assignee and discarding it, which the owner caught himself.
#
# Honouring it rather than refusing it, though refusing was the other candidate.
# The rules that ship with Tira say backlog means parked on a condition and is
# not an inbox; forcing every card through backlog puts every new card in the
# state those rules forbid. A card should be able to start where the work is.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T23:40:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Where it starts', dir => $root, members => ['michael'],
    columns => ['backlog, planning, implement, done'],
    sow_prefix => 'WSS', epic_prefix => 'WSE', ticket_prefix => 'WST',
);

sub column_of {
    my ($ref) = @_;
    return $tira->record_show( project => $root, ref => $ref )->{column};
}

# What an agent actually types, which is the only place the column is answered.
# create_record returns exactly what it stored - that is its own promise, and
# the column is the directory rather than a stored field - so naming it belongs
# to the layer that talks to agents, beside the reminder it already adds there.
sub create_cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'record.create', type => 'ticket', tira => $tira,
            argv => [ '-o', 'json', @argv ] ) };
    };
    return ( $status, $status == 0 ? Tira::json_decode($out) : {}, $err );
}

# --- created where it was asked for ------------------------------------------

my ( $status, $claimed ) = create_cli( '--title', 'Claimed into the column the work is in',
    '--column', 'planning' );
is( $status, 0, 'a card is created with a column' );
is( $claimed->{column}, 'planning', 'and the answer names the column that was asked for' );
is( column_of( $claimed->{ref} ), 'planning',
    'and reading it back off the board agrees, which is where the old behaviour disagreed' );

# --- and nothing changed for a card that named no column ---------------------
#
# Every board expects a plain create to land in backlog, and this must not
# become a change to that.

my ( undef, $plain ) = create_cli( '--title', 'Nobody said where' );
is( $plain->{column}, 'backlog', 'a card created without a column still lands in backlog' );
is( column_of( $plain->{ref} ), 'backlog', 'on the board as well as in the answer' );

# --- and the engine still answers with exactly what it stored -----------------
#
# The promise create_record makes, and the reason the column is added a layer
# up. A record that carried a field the board does not store would be the first
# place two copies of one fact could drift.

my $stored = $tira->create_record( project => $root, type => 'ticket',
    title => 'Straight from the engine', column => 'planning' );
ok( !exists $stored->{column},
    'the engine returns what it wrote, and the column is the directory, not a field it wrote' );
is( column_of( $stored->{ref} ), 'planning', 'while the card really is in that column' );

# --- a column that does not exist is refused ----------------------------------
#
# The point of the whole card: an argument that cannot be honoured must not be
# accepted. Landing it in backlog with a typo'd column is the original fault
# wearing a different hat.

my $unknown = !eval {
    $tira->create_record( project => $root, type => 'ticket',
        title => 'Into thin air', column => 'planing' );
    1;
};
ok( $unknown, 'a column that does not exist is refused rather than quietly ignored' );
like( $@, qr/planing/, 'and the refusal names what was typed' );

# --- and so is creating something already set aside ---------------------------
#
# discard is where work goes when it is dropped. A card created there was never
# work, and the board keeps that column for a reason.

my $aside = !eval {
    $tira->create_record( project => $root, type => 'ticket',
        title => 'Born discarded', column => 'discard' );
    1;
};
ok( $aside, 'creating a card straight into discard is refused' );
like( $@, qr/where work is set aside/, 'refused for being discard, not for the column being unknown' );

# --- the counter is not spent by a refusal ------------------------------------
#
# A refused create must leave the board exactly as it was. Burning a reference
# number on a card that was never made would leave a gap nobody can explain.

my $next = $tira->create_record( project => $root, type => 'ticket',
    title => 'The one after the refusals' );
is( $next->{ref}, 'WST-004',
    'a refused create spends no reference number, so the sequence has no unexplained gaps' );

# --- it works for every kind of card ------------------------------------------
#
# ticket is what all three reports used, and fixing only that would leave the
# same silence on the other two.

for my $type (qw(sow epic)) {
    my $made = $tira->create_record( project => $root, type => $type,
        title => "A $type that starts in planning", column => 'planning' );
    is( column_of( $made->{ref} ), 'planning',
        "a $type is created in the column it was asked for too" );
}

done_testing;

__END__

=head1 NAME

143-a-card-starts-where-it-was-put.t - a card is created in the column it was asked for

=head1 DESCRIPTION

C<ticket.create> accepted C<--column>, discarded it, and reported success, so
every card landed in backlog while the caller believed otherwise. Three projects
reported it in one evening; one of them had adopted the flag specifically to
claim cards into a working column, and recorded in two cards' gate records a
column those cards had never occupied.

The column is now honoured. A column that does not exist is refused, and so is
creating a card directly into discard - a card set aside before it exists is not
work. A create that names no column still lands in backlog, and a refused create
spends no reference number.

=cut
