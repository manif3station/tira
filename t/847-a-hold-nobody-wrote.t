#!/usr/bin/env perl
# unpushed-work has no hold for commits belonging to cards parked in his
# pending-push review gate.
#
# TKT-847, filed from a standing police-outstanding hunt: on 2026-09-01 he
# added a review gate that makes "a commit sitting unpushed" the NORMAL state
# for a card at pending-push - "the agent fills it; only he empties it", and
# "cards accumulating in pending-push is the normal state and is NOT a
# backlog to drain". unpushed-work does not know this and reports every
# unpushed commit regardless, which means the only action that silences it is
# pushing - the one thing his own gate forbids.
#
# Modeled directly on t/107-police-world-fires.t's own real-repository
# harness: a real git repo IS the board root (as t/107 sets up), so a commit
# subject naming a real card ref is exercised through the genuine dispatcher
# (police_world -> police_pass), nothing injected.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
require Tira::CLI::Police;
require Tira::CLI::Serve;

my $git = _which('git');
plan skip_all => 'git is not installed, and this rule is about a repository'
  if !$git;

my $tmp = tempdir( CLEANUP => 1 );

my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Held', dir => $root, members => [ 'michael', 'claude' ],
    columns    => ['backlog, pending-push, push, install, done'],
    sow_prefix => 'HLS', epic_prefix => 'HLE', ticket_prefix => 'HLT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

sub run_in {
    my ( $where, @c ) = @_;
    my @command = shift @c;
    push @command, ( '-C', $where ) if defined $where && $command[0] =~ /git\z/;
    return Tira::CLI::Serve::_reading( @command, @c );
}
sub _which {
    my ($program) = @_;
    for my $directory ( File::Spec->path ) {
        my $path = File::Spec->catfile( $directory, $program );
        return $path if -x $path;
    }
    return undef;
}

run_in( $root, $git, 'init', '--quiet', '-b', 'master' );
run_in( $root, $git, 'config', 'user.email', 'test@example.invalid' );
run_in( $root, $git, 'config', 'user.name', 'A Test' );
run_in( $root, $git, 'config', 'commit.gpgsign', 'false' );

open my $seed, '>', File::Spec->catfile( $root, 'README' ) or die $!;
print {$seed} "a repository\n";
close $seed;
run_in( $root, $git, 'add', 'README' );
run_in( $root, $git, 'commit', '--quiet', '-m', 'the first commit' );
my $upstream = File::Spec->catdir( $tmp, 'upstream.git' );
run_in( undef, $git, 'init', '--quiet', '--bare', $upstream );
run_in( $root, $git, 'remote', 'add', 'origin', $upstream );
run_in( $root, $git, 'push', '--quiet', '-u', 'origin', 'master' );

# A real card, parked exactly where his gate parks it.
my $held = $tira->create_record( project => $root, type => 'ticket', title => 'held for his review' );
$tira->record_move( author => 'claude', project => $root, ref => $held->{ref}, column => 'pending-push' );

sub commit_naming {
    my ($ref) = @_;
    open my $fh, '>>', File::Spec->catfile( $root, 'WORK' ) or die $!;
    print {$fh} "$ref\n";
    close $fh;
    run_in( $root, $git, 'add', 'WORK' );
    run_in( $root, $git, 'commit', '--quiet', '-m', "$ref more work" );
}

sub sitting_violations {
    $tira->policy_add( project => $root, rule => 'unpushed-work', age => '0s', action => 'log-only' );
    my $world  = Tira::CLI::Police::police_world( tira => $tira, project => $root );
    my $result = $tira->police_pass( project => $root, store => $store, world => $world );
    my @found  = @{ $result->{violations} };
    for my $policy ( @{ $tira->policy_list( project => $root ) } ) {
        $tira->policy_remove( project => $root, id => $policy->{id} );
    }
    return \@found;
}

# An age of zero means "more than zero seconds ago", so the sleep has to come
# AFTER the commit whose age is being measured - the same shape t/107 uses,
# and getting the order backwards here is exactly the kind of red test that
# passes on the shape of absence rather than on the fix.

# --- every unpushed commit belongs to a card in pending-push: silence ------

commit_naming( $held->{ref} );
sleep 1;
my $quiet = sitting_violations();
is( scalar @{$quiet}, 0,
    'HELD: every unpushed commit belongs to a card sitting in his pending-push '
      . 'review gate, so unpushed-work says nothing - pushing to silence it '
      . 'would breach the very gate the finding would be complaining about' );

# --- a commit belonging to a card PAST the gate: reports as always ---------

my $shipped = $tira->create_record( project => $root, type => 'ticket', title => 'already shipped' );
for my $column (qw(pending-push push install done)) {
    $tira->record_move( author => 'claude', project => $root, ref => $shipped->{ref}, column => $column );
}
commit_naming( $shipped->{ref} );
sleep 1;
my $past_gate = sitting_violations();
is( scalar @{$past_gate}, 1,
    'PAST THE GATE: a commit whose card has already reached done is not the '
      . 'normal-and-waiting case his gate describes, so unpushed-work reports '
      . 'exactly as it always has' );

# --- Codex review: a subject naming TWO cards checks BOTH, not just the ----
# first match. A commit that names a held card first and a shipped one
# second must not be silenced by the first ref alone.

{
    open my $fh, '>>', File::Spec->catfile( $root, 'WORK' ) or die $!;
    print {$fh} "mixed\n";
    close $fh;
    run_in( $root, $git, 'add', 'WORK' );
    run_in( $root, $git, 'commit', '--quiet', '-m', "$held->{ref} pending work; $shipped->{ref} shipped" );
    sleep 1;
    my $mixed = sitting_violations();
    is( scalar @{$mixed}, 1,
        'A SUBJECT NAMING TWO CARDS CHECKS BOTH: the held ref alone used to '
          . 'silence this rule by being the first match - every ref in the '
          . 'subject has to be at pending-push, not merely the first found' );
}

# --- a commit that maps to no card at all: the forgotten-commit case -------

sleep 1;
my $orphan_root = File::Spec->catdir( $tmp, 'orphan' );
$tira->project_new(
    name => 'Orphan', dir => $orphan_root, members => [ 'michael', 'claude' ],
    columns    => ['backlog, pending-push, done'],
    sow_prefix => 'OPS', epic_prefix => 'OPE', ticket_prefix => 'OPT',
);
run_in( $orphan_root, $git, 'init', '--quiet', '-b', 'master' );
run_in( $orphan_root, $git, 'config', 'user.email', 'test@example.invalid' );
run_in( $orphan_root, $git, 'config', 'user.name', 'A Test' );
run_in( $orphan_root, $git, 'config', 'commit.gpgsign', 'false' );
open my $orphan_seed, '>', File::Spec->catfile( $orphan_root, 'README' ) or die $!;
print {$orphan_seed} "a repository\n";
close $orphan_seed;
run_in( $orphan_root, $git, 'add', 'README' );
run_in( $orphan_root, $git, 'commit', '--quiet', '-m', 'the first commit' );
my $orphan_upstream = File::Spec->catdir( $tmp, 'orphan-upstream.git' );
run_in( undef, $git, 'init', '--quiet', '--bare', $orphan_upstream );
run_in( $orphan_root, $git, 'remote', 'add', 'origin', $orphan_upstream );
run_in( $orphan_root, $git, 'push', '--quiet', '-u', 'origin', 'master' );
open my $forgotten, '>', File::Spec->catfile( $orphan_root, 'STRAY' ) or die $!;
print {$forgotten} "stray\n";
close $forgotten;
run_in( $orphan_root, $git, 'add', 'STRAY' );
run_in( $orphan_root, $git, 'commit', '--quiet', '-m', 'a commit with no card name in it at all' );
sleep 1;

$tira->policy_add( project => $orphan_root, rule => 'unpushed-work', age => '0s', action => 'log-only' );
my $orphan_world  = Tira::CLI::Police::police_world( tira => $tira, project => $orphan_root );
my $orphan_result = $tira->police_pass( project => $orphan_root, store => File::Spec->catdir( $tmp, 'orphan-state' ), world => $orphan_world );
is( scalar @{ $orphan_result->{violations} }, 1,
    'THE FORGOTTEN-COMMIT CASE IS NOT LOST: a commit naming no card at all '
      . 'still reports - the rule this hold must not silence by accident' );

done_testing();

__END__

=head1 NAME

847-a-hold-nobody-wrote.t - unpushed-work stops demanding a push his own gate forbids

=head1 WHY

TKT-847: on 2026-09-01 he made "unpushed and waiting for my review" the
normal state for a card at pending-push. unpushed-work did not know this,
so the only action that silences it is pushing - which breaches the gate the
finding would be about.

=head1 WHAT IS ASSERTED

Every unpushed commit belonging to a card in pending-push: silent. A commit
whose card has moved past the gate (push, install, done): reports exactly as
before. A commit naming no card at all: the forgotten-commit case, still
reported - the hold must not cost this rule its actual purpose.

=cut
