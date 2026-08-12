#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-11T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
sub at { $now = $_[0]; return $now }

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Policed', dir => $root, members => ['michael'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'PCS', epic_prefix => 'PCE', ticket_prefix => 'PCT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

# Police touches git, the process table and Docker; the engine touches none of
# them and is not going to start. So the world is handed in, which also means
# every environment rule can be tested without a repository, a container or a
# running process anywhere near this file.
my %world = ( branches => [], worktrees => [], processes => [], containers => [], commits => [] );
sub police {
    my (%args) = @_;
    return $tira->police_pass(
        project => $root, store => $store, world => {%world}, %args );
}

# --- nothing declared -----------------------------------------------------

# A board nobody asked to be watched is not a board with no problems. Police
# refuses to pretend rather than running and guarding nothing.
my $idle = police();
ok( !$idle->{watching}, 'with no policies declared, police is not watching' );
like( $idle->{advice}, qr/tira\.policy/,
    'and says what the owner should paste to the agent to set some' );
is_deeply( $idle->{violations}, [], 'reporting nothing, because it was asked to watch nothing' );

# --- watching -------------------------------------------------------------

$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Bare' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );

my $pass = police();
ok( $pass->{watching}, 'with a policy declared, police is watching' );
is( scalar @{ $pass->{violations} }, 1, 'and reports what it found' );
like( $pass->{violations}[0]{id}, qr/\AVIO-\d{4}\z/, 'through the ledger, so it has a number' );

# --- the environment rules ------------------------------------------------

# A card being implemented should have a branch of its own and a worktree of
# its own. Two cards in one tree means two sets of changes interleaved, and
# the first failing test cannot say which card caused it.
$tira->policy_add( project => $root, rule => 'card-sandbox-missing',
    enter => 'implement', sandbox => '/sandboxes', action => 'bridge-reminder' );
my @sandbox = grep { $_->{rule} eq 'card-sandbox-missing' } @{ police()->{violations} };
is( scalar @sandbox, 1, 'a card being implemented with no branch and no worktree is reported' );
like( $sandbox[0]{detail}, qr/branch/, 'saying the branch is missing' );

my @with_branch = grep { $_->{rule} eq 'card-sandbox-missing' }
  @{ police( world => { %world, branches => [ $card->{ref} ] } )->{violations} };
is( scalar @with_branch, 1, 'a branch on its own is not enough' );
like( $with_branch[0]{detail}, qr/worktree|sandbox/, 'because the worktree is still missing' );

my $equipped = police( world => {
    %world, branches => [ $card->{ref} ],
    worktrees => [ "/sandboxes/$card->{ref}" ] } );
is( scalar( grep { $_->{rule} eq 'card-sandbox-missing' } @{ $equipped->{violations} } ), 0,
    'with both, it falls silent' );

$tira->policy_add( project => $root, rule => 'leftover-process',
    pattern => 'until sleep', age => '30m', action => 'bridge-reminder' );
my $littered = police( world => { %world,
    processes => [ { command => 'bash -c until sleep 25', started_at => '2026-08-11T08:00:00Z' } ] } );
my @left = grep { $_->{rule} eq 'leftover-process' } @{ $littered->{violations} };
is( scalar @left, 1, 'a process the agent started and never stopped is reported' );
like( $left[0]{detail}, qr/until sleep/, 'naming what is still running' );

my $recent = police( world => { %world,
    processes => [ { command => 'bash -c until sleep 25', started_at => '2026-08-11T08:50:00Z' } ] } );
is( scalar( grep { $_->{rule} eq 'leftover-process' } @{ $recent->{violations} } ), 0,
    'and one started recently is left alone, because work in progress is not litter' );

$tira->policy_add( project => $root, rule => 'leftover-container',
    pattern => 'perl-test', age => '30m', action => 'bridge-reminder' );
my $still_up = police( world => { %world,
    containers => [ { name => 'skills-perl-test-run-abc', started_at => '2026-08-11T08:00:00Z' } ] } );
is( scalar( grep { $_->{rule} eq 'leftover-container' } @{ $still_up->{violations} } ), 1,
    'a test container still alive is reported, because one has corrupted a coverage figure before' );

$tira->policy_add( project => $root, rule => 'commit-without-card', action => 'bridge-reminder' );
my $loose = police( world => { %world,
    commits => [ { sha => 'abc1234', subject => 'tidy up a few things' } ] } );
is( scalar( grep { $_->{rule} eq 'commit-without-card' } @{ $loose->{violations} } ), 1,
    'a commit naming no card is reported' );
my $attributed = police( world => { %world,
    commits => [ { sha => 'abc1234', subject => "$card->{ref} do the thing" } ] } );
is( scalar( grep { $_->{rule} eq 'commit-without-card' } @{ $attributed->{violations} } ), 0,
    'and one naming a card is not' );

# Work happening while the board says nothing is happening. This is the drift
# the commit gate catches at commit time; police catches it while it is still
# going on, which is earlier and cheaper.
$tira->policy_add( project => $root, rule => 'work-without-card',
    age => '15m', action => 'bridge-reminder' );
my $drifting = police( world => { %world, working_since => '2026-08-11T08:30:00Z' } );
my @adrift = grep { $_->{rule} eq 'work-without-card' } @{ $drifting->{violations} };
is( scalar @adrift, 1, 'a tree changing with no card at a working gate is reported' );
like( $adrift[0]{detail}, qr/no card at a working gate/, 'saying exactly that' );

is( scalar( grep { $_->{rule} eq 'work-without-card' }
        @{ police( world => { %world, working_since => '2026-08-11T08:30:00Z',
                card_in_progress => 'PCT-001' } )->{violations} } ), 0,
    'and a card at a working gate makes it right' );
is( scalar( grep { $_->{rule} eq 'work-without-card' }
        @{ police( world => { %world, working_since => '2026-08-11T08:55:00Z' } )->{violations} } ), 0,
    'while a tree only just touched is somebody starting, not somebody drifting' );

# Push is part of done here, so work sitting unpushed is work that is not done
# while the board says it is.
$tira->policy_add( project => $root, rule => 'unpushed-work',
    age => '1h', action => 'bridge-reminder' );
is( scalar( grep { $_->{rule} eq 'unpushed-work' }
        @{ police( world => { %world, unpushed_since => '2026-08-11T07:30:00Z' } )->{violations} } ), 1,
    'commits sitting unpushed past the age are reported' );
is( scalar( grep { $_->{rule} eq 'unpushed-work' }
        @{ police( world => { %world, unpushed_since => '2026-08-11T08:30:00Z' } )->{violations} } ), 0,
    'and recent ones are not, because committing then pushing is not instant' );
is( scalar( grep { $_->{rule} eq 'unpushed-work' } @{ police()->{violations} } ), 0,
    'with nothing unpushed there is nothing to say' );

# The board is deliberately outside git, so a backup is the only thing between
# a mistake and losing the work. This project lost its board once already.
$tira->policy_add( project => $root, rule => 'board-unbacked',
    age => '2h', action => 'bridge-reminder' );
my @never = grep { $_->{rule} eq 'board-unbacked' } @{ police()->{violations} };
is( scalar @never, 1, 'a board that has never been backed up is reported' );
like( $never[0]{detail}, qr/never/, 'saying so plainly rather than reporting a stale date' );
is( scalar( grep { $_->{rule} eq 'board-unbacked' }
        @{ police( world => { %world, backed_up_at => '2026-08-11T05:00:00Z' } )->{violations} } ), 1,
    'and one backed up too long ago is reported too' );
is( scalar( grep { $_->{rule} eq 'board-unbacked' }
        @{ police( world => { %world, backed_up_at => '2026-08-11T08:30:00Z' } )->{violations} } ), 0,
    'while a recent backup silences it' );

# --- police never writes to the board -------------------------------------

require File::Find;
require Digest::SHA;
sub fingerprint {
    my @found;
    File::Find::find(
        { no_chdir => 1, wanted => sub {
            return if !-f $File::Find::name;
            open my $fh, '<:raw', $File::Find::name or return;
            my $bytes = do { local $/; <$fh> };
            close $fh;
            push @found, "$File::Find::name:" . Digest::SHA::sha256_hex($bytes);
        } }, File::Spec->catdir( $root, '.tira' ) );
    return [ sort @found ];
}
my $before = fingerprint();
police() for 1 .. 3;
is_deeply( fingerprint(), $before, 'a full police pass changes not one byte of the board' );

# --- a transient failure is survived --------------------------------------

# Police is meant to be left running for days. A board mid-write, a lock held
# for a moment, a file being replaced - none of those are reasons to die.
{
    my $broken = Tira->new( clock => sub {$now} );
    no warnings 'redefine';
    local *Tira::policy_evaluate = sub { die "Board is locked\n" };
    my $survived = eval {
        $broken->police_pass( project => $root, store => $store, world => {%world} );
    };
    ok( $survived, 'a board that cannot be read does not kill the pass' );
    like( $survived->{error}, qr/locked/, 'and the reason is reported rather than swallowed' );
    is_deeply( $survived->{violations}, [],
        'with nothing invented to fill the gap, because a guess here is worse than a silence' );
}

# --- what the owner sees --------------------------------------------------

my $escalating = File::Spec->catdir( $tmp, 'escalate' );
my @terminal;
for my $round ( 1 .. 6 ) {
    at( sprintf '2026-08-11T10:%02d:00Z', $round );
    my $result = $tira->police_pass(
        project => $root, store => $escalating, world => {%world} );
    push @terminal, @{ $result->{terminal} };
}
is( scalar @terminal, scalar( grep { $_ } @terminal ),
    'nothing empty is ever put in front of the owner' );
ok( scalar @terminal >= 1, 'a problem ignored long enough reaches his terminal' );
like( $terminal[0], qr/paste to the agent/,
    'carrying something he can hand straight back to the agent' );

# --- saying why it is going ------------------------------------------------

# A supervisor that dies quietly is worse than none, because its silence reads
# as everything being fine.
my $farewell = $tira->police_farewell( reason => 'interrupted' );
like( $farewell, qr/interrupted/, 'police says why it is stopping' );
like( $farewell, qr/no longer watching/i, 'and that it has stopped watching, in as many words' );

done_testing;

__END__

=head1 NAME

82-police.t - TKT-017 the process the owner leaves running

=head1 DESCRIPTION

Police follows the policies the agent declared, and nothing else. With none
declared it refuses to pretend: it says so, and gives the owner something to
paste to the agent. A watcher that runs while guarding nothing is worse than
no watcher, because its presence reads as cover.

The six environment rules live here rather than in the engine. They need git,
the process table and Docker, and the engine's documented guarantee is that
Tira invokes no shell - so the world is handed in as facts. That also makes
every one of them testable without a repository, a container or a running
process anywhere near this file.

Two properties matter more than the rules themselves. A full pass changes not
one byte of the board, checked by fingerprint rather than by intention. And a
transient failure - a board mid-write, a lock held for a moment - is survived
and reported rather than fatal, with nothing invented to fill the gap, because
police guessing is worse than police silent.

Finally it says why it is going. A supervisor that dies quietly is worse than
none at all, because its silence reads as everything being fine.

=cut
