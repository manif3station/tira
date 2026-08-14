#!/usr/bin/env perl
# A rule about the machine says what it asked the machine.
#
# developer-dashboard read this off their bridge:
#
#     missing branch and the work tree it records,
#     /home/mv/dd-worktree-sandbox/dd-532, which is not there for DD-532
#
# and all three things it names existed: the directory, the git work tree, and
# the branch. They offered a hypothesis and were careful to call it one - case.
# Their card is DD-532 and their tooling names the branch and the directory
# dd-532, because git branches there are conventionally lower case. They said
# plainly they could not confirm it cheaply.
#
# They were right about the branch. The check looks for a branch named exactly
# after the card reference, and a reference is upper case by construction, so on
# any project that names branches in lower case it can never match.
#
# The work tree half is theirs to see rather than mine to guess: it compares the
# path recorded on the card against the paths git reports, and both look right
# from here. What the message never said is what it asked for or what came back
# - so a rule that reads the machine gave its reader nothing to check against
# the machine, which is the fault they can see from where they are standing.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-14T16:00:00Z'} );
my $store = File::Spec->catdir( $tmp, 'police' );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Sandboxes', dir => $root, members => ['michael'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SBS', epic_prefix => 'SBE', ticket_prefix => 'SBT',
);
$tira->policy_add( project => $root, rule => 'card-sandbox-missing',
    enter => 'implement', sandbox => '/sandboxes', action => 'bridge-reminder' );

sub card {
    my (%args) = @_;
    my $made = $tira->create_record( project => $root, type => 'ticket',
        title => $args{title}, ( $args{sandbox} ? ( sandbox => $args{sandbox} ) : () ) );
    $tira->record_move( project => $root, ref => $made->{ref}, column => 'implement' );
    return $made->{ref};
}

sub reported {
    my (%world) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store, world => \%world );
    return [ grep { $_->{rule} eq 'card-sandbox-missing' } @{ $pass->{violations} } ];
}

my $ref = card( title => 'Being worked in a sandbox', sandbox => '/sandboxes/sbt-001' );
my $lower = lc $ref;

# --- the branch that is there under another case ------------------------------------
#
# Their case, exactly: a branch named for the card in lower case, which is what
# git conventions produce, against a reference that is upper case by
# construction.

my $found = reported(
    branches  => [$lower],
    worktrees => ['/sandboxes/sbt-001'],
);
is( scalar @{$found}, 1, 'the card is still reported, because the branch does not match exactly' );
like( $found->[0]{detail}, qr/\Q$ref\E/, 'and the violation names the branch it looked for' );
like( $found->[0]{detail}, qr/\Q$lower\E/,
    'and the one that differs from it only in case, which is what they had to guess' );
unlike( $found->[0]{detail}, qr/which is not there/,
    'and does not say a branch is not there when it is there under another case' );

# --- a branch that is genuinely absent ------------------------------------------------
#
# The message must not soften into uselessness. A card with no branch at all is
# what the rule is for.

my $nothing = reported( branches => ['something-else'], worktrees => ['/sandboxes/sbt-001'] );
is( scalar @{$nothing}, 1, 'a card with no branch of its own is reported' );
like( $nothing->[0]{detail}, qr/\Q$ref\E/, 'naming the branch it wanted' );
like( $nothing->[0]{detail}, qr/\b1 branch\b|\bbranches\b/,
    'and saying what the machine reported, so a reader can check it against the machine' );

# --- and the work tree half ---------------------------------------------------------------
#
# Theirs looked right from every direction and was still called missing. The
# message never said how many work trees came back, so an empty list - police
# pointed at a repository that is not the one holding the trees - looked
# identical to a tree that really is gone.

my $none = reported( branches => [$ref], worktrees => [] );
is( scalar @{$none}, 1, 'a card whose recorded work tree is not among them is reported' );
like( $none->[0]{detail}, qr{/sandboxes/sbt-001}, 'naming the work tree it looked for' );
like( $none->[0]{detail}, qr/\bnone\b|\b0 work trees\b|reported no work trees/i,
    'and saying the machine reported none at all, which is a different fault from one being gone' );

my $others = reported( branches => [$ref], worktrees => [ '/sandboxes/other', '/sandboxes/third' ] );
like( $others->[0]{detail}, qr/\b2\b/,
    'and how many it did report, when it reported some' );

# --- while a card with everything is silent ------------------------------------------------

is( scalar @{ reported( branches => [$ref], worktrees => ['/sandboxes/sbt-001'] ) }, 0,
    'a card with its branch and its work tree is not reported at all' );

done_testing;

__END__

=head1 NAME

165-what-it-looked-for.t - a rule about the machine says what it asked the machine

=head1 DESCRIPTION

C<card-sandbox-missing> reported a branch and a work tree as absent while both
existed, and said nothing about what it had looked for. The branch half was a
real mismatch: it wants a branch named exactly after the card reference, which
is upper case by construction, and the reporter's branches are conventionally
lower case.

The violation now names the branch it wanted, names one that differs only in
case rather than claiming nothing is there, names the work tree it looked for,
and says how many the machine reported - so an empty list, which is police
pointed at the wrong repository, can be told from a tree that is really gone.

=cut
