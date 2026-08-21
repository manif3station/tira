#!/usr/bin/env perl
# A bridge line describes the board police is watching, not the one it is
# standing in.
#
# Every line carries the way down to its card - "via SOW-002 > EPC-003" - so the
# core agent can walk a violation to whoever holds it. That path was looked up
# on the wrong board. The police command calls bridge_write with the store and
# the violations and not the project, so card_path falls back to discovering a
# project from the working directory: whatever Tira board the process happens to
# be standing in.
#
# Found on 2026-08-13 while proving the answer-waiting rule end to end, because
# he asked for exactly that: "have you test the police and the message on the
# bridge with event properly? make sure they work." The rule worked. The line it
# produced named a hierarchy that does not exist on the board it was about:
#
#   ... | via SOW-001 > EPC-001 | TKT-001 | Q-001 was answered ...
#
# on a board with no statements of work and no epics at all. SOW-001 and EPC-001
# are cards on the Tira development board - the directory police was run from.
# The same pass from a directory that is no Tira project said "via nobody".
#
# It is worse than a wrong label. That path exists so somebody can follow it,
# and it was sending them to another board's records. And it is invisible on the
# one board where it cannot go wrong: this repository, where police is run from
# the project it watches.

use strict;
use warnings;

use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-13T12:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

# The board being watched: one card, no parent, nothing above it.
my $watched = File::Spec->catdir( $tmp, 'watched' );
$tira->project_new(
    name => 'Watched', dir => $watched, members => ['ada', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WAS', epic_prefix => 'WAE', ticket_prefix => 'WAT',
);
my $card = $tira->create_record( project => $watched, type => 'ticket', title => 'Bare' );
$tira->record_move(author => 'claude',  project => $watched, ref => $card->{ref}, column => 'implement' );
$tira->policy_add( project => $watched, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );

# Another Tira board entirely, with a real hierarchy on it - the shape of the
# directory police happened to be standing in.
my $elsewhere = File::Spec->catdir( $tmp, 'elsewhere' );
$tira->project_new(
    name => 'Elsewhere', dir => $elsewhere, members => ['ada', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ELS', epic_prefix => 'ELE', ticket_prefix => 'WAT',
);
my $sow = $tira->create_record( project => $elsewhere, type => 'sow', title => 'Some other work' );
my $epic = $tira->create_record( project => $elsewhere, type => 'epic', title => 'Some other epic' );
$tira->hierarchy_link( project => $elsewhere, parent => $sow->{ref}, child => $epic->{ref} );
my $twin = $tira->create_record( project => $elsewhere, type => 'ticket', title => 'A card with the same reference' );
$tira->hierarchy_link( project => $elsewhere, parent => $epic->{ref}, child => $twin->{ref} );
is( $twin->{ref}, $card->{ref},
    'the two boards use the same ticket prefix, so the same reference exists on both' );

sub watched_from {
    my ($where) = @_;
    my $store = File::Spec->catdir( $tmp, 'police-' . ( $where eq $elsewhere ? 'elsewhere' : 'nowhere' ) );
    my $was = getcwd();
    chdir $where or die "cannot enter $where: $!";
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $watched; Tira::CLI->run( command => 'police', tira => $tira,
            argv => [ '--once', '--store', $store ] ) };
    }
    chdir $was or die "cannot return to $was: $!";
    return join "\n", @{ $tira->bridge_backlog( store => $store, lines => 50 ) };
}

# --- from a directory that is no Tira project -------------------------------
#
# The card has nothing above it, so there is nothing to say about a path.

my $from_nowhere = watched_from($tmp);
like( $from_nowhere, qr/\Q$card->{ref}\E/, 'the violation reaches the bridge' );
like( $from_nowhere, qr/via nobody/, 'and says the card has nothing above it' );

# --- from inside a different Tira board -------------------------------------
#
# The whole defect. Standing somewhere else must not change what is reported
# about the board being watched.

my $from_elsewhere = watched_from($elsewhere);
like( $from_elsewhere, qr/\Q$card->{ref}\E/, 'the same violation reaches the bridge' );
unlike( $from_elsewhere, qr/\Q$sow->{ref}\E/,
    'and does not name a statement of work from the board police was standing in' );
unlike( $from_elsewhere, qr/\Q$epic->{ref}\E/, 'nor its epic' );
like( $from_elsewhere, qr/via nobody/,
    'it says what is true of the watched board, wherever police was run from' );

# --- and a real path is still reported ---------------------------------------
#
# Nothing here may take the path away. It is the whole reason the field exists.

my $parent = $tira->create_record( project => $watched, type => 'epic', title => 'Real parent' );
$tira->hierarchy_link( project => $watched, parent => $parent->{ref}, child => $card->{ref} );

# Past the first rung of the quiet ladder. The same violation was said a moment
# ago, and it is not said again until there has been time to fix it - so a pass
# at a frozen clock would leave the old line standing and prove nothing about
# the new one.
$now = '2026-08-13T12:30:00Z';
my $with_parent = watched_from($elsewhere);
like( $with_parent, qr/via .*\Q$parent->{ref}\E/,
    'a card that really is under an epic says so, and names the watched board\'s epic' );

done_testing;

__END__

=head1 NAME

128-the-bridge-names-the-watched-board.t - a bridge line describes the watched board

=head1 DESCRIPTION

Every bridge line carries the way down to its card so the core agent can walk a
violation to whoever holds it. The police command wrote the bridge without
saying which project it was watching, so that path was discovered from the
working directory instead - and a violation on one board was reported with a
hierarchy from another.

The same pass now reports the same path wherever it is run from: the watched
board's records, or nothing.

=cut
