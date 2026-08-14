#!/usr/bin/env perl
# The agent is told when Tira has been upgraded under it.
#
# His request. When a new Tira is installed nothing tells the agent: the owner
# gets the setup prompt in his own terminal when police starts, and the agent -
# which is the party that would have to read the changes, learn the new commands
# and declare the new rules - gets nothing at all. New rules land and the board
# goes on not declaring them, which is silent in exactly the way a rule being
# obeyed is.
#
# His rough words, kept because they name the three things to do: "Tira has been
# updated. Review the new changes d2 tira.changes and checkout what new commands
# have been added d2 tira.usage. Also, there might be new options to setup
# project policies to improve the project workflow. Compare them and see any
# gaps need to be filled."
#
# The gap-finding half already has a command - tira.policy.undeclared answers
# exactly "which rules has this project neither declared nor declined" - so the
# line points at that rather than asking anybody to compare two lists by eye.
#
# Once per version, not once per start. Police restarts to pick up a new
# version, so a line written on every start would repeat for ever on a loop, and
# this project has spent the evening on what repetition costs a channel.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-15T08:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Upgraded', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'UPS', epic_prefix => 'UPE', ticket_prefix => 'UPT',
);
$tira->project_update( project => $root, agent => 'claude' );
$tira->policy_add( project => $root, rule => 'discard-unexplained',
    action => 'bridge-reminder' );

sub world { return { branches => [], worktrees => [], processes => [], containers => [] } }
sub pass { return $tira->police_pass( project => $root, store => $store, world => world() ) }

# --- a board that has not been told -------------------------------------------------
#
# Nothing is wrong with this board. The upgrade note must not depend on there
# being a violation to hang it on, because the boards most in need of hearing
# about new rules are the quiet ones.

my $first = pass();
is( scalar @{ $first->{violations} }, 0, 'nothing is wrong with this board' );

ok( $first->{upgraded}, 'and it is still told that Tira has moved' );
is( $first->{upgraded}{to}, $Tira::VERSION, 'naming the version it is now on' );
ok( !defined $first->{upgraded}{from},
    'with nothing to say about where it came from, the first time' );

# --- said once, however many times police starts ---------------------------------------
#
# Police restarts to pick up a new version, so a note written on every start
# would arrive on a loop for as long as nobody upgrades again.

my $second = pass();
ok( !$second->{upgraded}, 'a second pass on the same version says nothing' );

my $third = pass();
ok( !$third->{upgraded}, 'and nor does a third' );

# --- and again when the version really moves -------------------------------------------

{
    no warnings 'redefine', 'once';
    local $Tira::VERSION = '99.99';
    my $moved = pass();
    ok( $moved->{upgraded}, 'a genuinely new version is announced' );
    is( $moved->{upgraded}{to}, '99.99', 'naming what it moved to' );
    ok( defined $moved->{upgraded}{from},
        'and where it came from, which it knows because it told this board once already' );
}

# --- what the line actually says on the bridge --------------------------------------------
#
# The three things to do, in the shape every other line has. A note that said
# "Tira has been updated" and left the reader to work out what to run would be
# an interruption rather than an instruction.

{
    my $fresh = File::Spec->catdir( $tmp, 'bridge-store' );
    my $result = $tira->police_pass( project => $root, store => $fresh, world => world() );
    ok( $result->{upgraded}, 'a store that has never been told gets the note' );

    $tira->bridge_write( store => $fresh, project => $root,
        violations => $result->{violations}, settled => $result->{settled},
        upgraded => $result->{upgraded} );

    my $lines = $tira->bridge_backlog( store => $fresh, lines => 50 );
    my ($note) = grep { /UPGRADE/ } @{$lines};
    ok( $note, 'and it reaches the bridge' ) or diag( join "\n", @{$lines} );

    like( $note, qr/\bfor claude\b/,
        'addressed to the agent, who is the one who has to act on it' );
    like( $note, qr/\Q$Tira::VERSION\E/, 'naming the version' );
    like( $note, qr/tira\.changes/,      'pointing at what changed' );
    like( $note, qr/tira\.usage/,        'and at the commands that are new' );
    like( $note, qr/tira\.policy\.undeclared/,
        'and at the rules this board has neither declared nor declined, which is the gap he asked about' );
}

# --- a version going backwards is a change too ------------------------------------------------
#
# The store above was told about 99.99, and the process is back on the real
# version, so this board is now running something other than what it last heard.
# That is a rollback, and it deserves the same line for the same reason: the
# rules the agent learned about may not be there any more.
#
# Written after getting it wrong. The first version of this asserted silence
# here, on the assumption that only going forwards counts - which would have
# left an agent working from a rulebook the installed Tira no longer has.

{
    my $back = pass();
    ok( $back->{upgraded}, 'a board whose version went backwards is told as well' );
    is( $back->{upgraded}{to}, $Tira::VERSION, 'naming what it is on now' );
    is( $back->{upgraded}{from}, '99.99', 'and what it last heard, which is how a rollback reads' );

    my $settled = pass();
    ok( !$settled->{upgraded}, 'and once told, it is quiet again' );
}

done_testing;

__END__

=head1 NAME

175-a-new-tira-nobody-mentioned.t - the agent hears about an upgrade

=head1 DESCRIPTION

When a new Tira is installed the owner gets the setup prompt in his terminal and
the agent gets nothing - though the agent is the party that has to read the
changes, learn the new commands and declare the new rules.

Police now says it on the bridge, addressed to the agent, naming the version and
the three commands that act on it: C<tira.changes>, C<tira.usage> and
C<tira.policy.undeclared>. Said once per version rather than once per start,
because police restarts to pick up a new version and a line on every start would
repeat for ever.

It does not depend on there being a violation to hang it on: the boards most in
need of hearing about new rules are the quiet ones.

=cut
