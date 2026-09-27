#!/usr/bin/env perl
# card-sandbox-missing checks a card's claimed sandbox by asking whether it
# is IN the world's own worktree list - and that list is `git worktree list`
# run against the project's one declared repository. A sandbox that is an
# independent CLONE of that repository (its own .git, its own remote) is
# never a worktree of the declared checkout, so it can never appear there -
# the rule reports it missing even when it is a real, correctly-checked-out
# git repository sitting exactly where the card says.
#
# TKT-726, Michael's answer to Q-189: "run git against the card's own
# sandbox field directly", rather than only enumerating the one declared
# repository's branches/worktrees. This test builds a real independent
# clone on disk and checks it out to the card's own ref, so the fix has to
# actually run git against $record->{sandbox} to see it.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-27T00:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Cloned sandboxes', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'CSS', epic_prefix => 'CSE', ticket_prefix => 'CST',
);
mkdir File::Spec->catdir( $root, '.git' );
my $store = File::Spec->catdir( $tmp, 'police-state' );

$tira->policy_add( project => $root, rule => 'card-sandbox-missing',
    enter => 'implement', sandbox => '/sandboxes', action => 'log-only' );

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Worked in its own clone' );
$tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'implement' );

# --- an independent clone, its own .git, checked out to the card's ref -----

my $clone = File::Spec->catdir( $tmp, 'clone' );
mkdir $clone or die "mkdir $clone: $!";
system( 'git', '-C', $clone, 'init', '--quiet' ) == 0 or die 'git init failed';
system( 'git', '-C', $clone, 'config', 'user.email', 'a@b.c' );
system( 'git', '-C', $clone, 'config', 'user.name',  'Test' );
open my $fh, '>', File::Spec->catfile( $clone, 'README' ) or die $!;
print {$fh} "hi\n";
close $fh;
system( 'git', '-C', $clone, 'add', '.' ) == 0 or die 'git add failed';
system( 'git', '-C', $clone, 'commit', '--quiet', '-m', 'first' ) == 0 or die 'git commit failed';
system( 'git', '-C', $clone, 'checkout', '--quiet', '-b', $card->{ref} ) == 0 or die 'git checkout failed';

$tira->record_update( author => 'claude', project => $root, ref => $card->{ref}, sandbox => $clone );

sub police {
    my (%world) = @_;
    my $result = $tira->police_pass( project => $root, store => $store, world => {
        branches => [], worktrees => [], processes => [], containers => [], commits => [], %world } );
    return [ grep { $_->{rule} eq 'card-sandbox-missing' } @{ $result->{violations} } ];
}

# The declared project's own world scan (branches/worktrees) knows nothing
# about $clone - it is not a worktree of $root, it is a second repository
# entirely. The card's branch check still needs $branch{$record->{ref}} to
# pass, so the world is given it directly here (that half of the rule is
# unchanged by TKT-726 - only the sandbox/worktree half is).
my $findings = police( branches => [ $card->{ref} ] );
is( scalar @{$findings}, 0,
    'a sandbox that is its own independent clone, checked out to the card\'s ref, satisfies the rule '
  . 'even though it is not among the declared repository\'s own worktrees' )
  or diag( "false-fired: $findings->[0]{detail}" );

# --- the same clone, but checked out to the WRONG ref ----------------------

system( 'git', '-C', $clone, 'checkout', '--quiet', '-b', 'something-else' ) == 0
  or die 'git checkout failed';

my $wrong = police( branches => [ $card->{ref} ] );
is( scalar @{$wrong}, 1, 'a claimed clone checked out to the wrong branch is still reported' );
like( $wrong->[0]{detail}, qr/\Q$clone\E/, 'naming the clone the card claims' );

# --- a claimed path that simply is not a git repository at all -------------

my $not_a_repo = File::Spec->catdir( $tmp, 'not-a-repo' );
mkdir $not_a_repo or die "mkdir $not_a_repo: $!";
$tira->record_update( author => 'claude', project => $root, ref => $card->{ref}, sandbox => $not_a_repo );

my $bogus = police( branches => [ $card->{ref} ] );
is( scalar @{$bogus}, 1, 'a claimed path that is not a git repository at all is reported' );
like( $bogus->[0]{detail}, qr/\Q$not_a_repo\E/, 'naming the path the card claims' );

done_testing();

__END__

=head1 NAME

1161-a-sandbox-that-is-its-own-clone.t - card-sandbox-missing verifies an independent clone by asking git directly

=head1 DESCRIPTION

card-sandbox-missing used to check a card's claimed sandbox path only by
membership in C<$world-E<gt>{worktrees}>, itself C<git worktree list> run
against the ONE repository the project declared. A sandbox implemented as
an independent clone - its own C<.git>, its own remote, Michael's own
per-ticket working pattern for some projects - is never a worktree of that
declared repository, so it could never appear there and the rule reported
every such card as missing a sandbox it in fact had, correctly checked out.

TKT-726, Q-189: run git directly against the card's own C<sandbox> field to
verify it, rather than only asking the declared repository's own world scan.

=cut
