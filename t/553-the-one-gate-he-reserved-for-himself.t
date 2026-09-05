#!/usr/bin/env perl
# TKT-887. The pre-push hook asks tools/card-holes whether the cards named by
# the commits being pushed are COMPLETE. It never asks whether they have
# reached the push column - so a card sitting in pending-push, the queue that
# exists precisely because Michael and only Michael decides what ships, had
# its commit pushed anyway.
#
# MEASURED, not hypothetical: 51a22aa (TKT-854) committed 09:33:35 and pushed
# 09:48:54 in the 5.41 batch; the TKT-854 card reached pending-push at
# 10:01:50 - thirteen minutes AFTER its own commit was already on origin. Every
# existing check passed it: card-holes's unproven() only demands a fix_version
# at or past the push column, and pending-push sits one column short of it, so
# a well-formed card with 44 gate entries and one evidence item drew nothing.
#
# THE TRAP IN THE FIX (KD4): the hook falls back to sweeping the WHOLE BOARD
# when there is no remote ref - the by-hand and prove-the-gate path. A column
# check applied there would refuse every push on any board with a card in
# backlog, which is every board. It must apply only to the refs the commits
# being pushed actually name.
#
# WRITTEN RED.

use strict;
use warnings;

use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Run qw(run_capturing);
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

my $tira = Tira->new( clock => sub {'2026-09-05T08:00:00Z'} );
$tira->project_new(
    name    => 'Shipping',
    dir     => $root,
    members => ['claude'],
    columns => ['backlog, implement, verify, pending-push, push, install, done'],
    sow_prefix => 'SHS', epic_prefix => 'SHE', ticket_prefix => 'SHT',
);

my $parent = $tira->create_record( project => $root, type => 'epic',
    title => 'The release this commit belongs to' );

# Everything the engine asks of a complete card, so card-holes's OTHER checks
# (holes/stalled/premature/unproven) have nothing to say about it - what is
# being tested here is the one question none of them ask.
sub complete_card {
    my ($title) = @_;
    my $card = $tira->create_record(
        project => $root, type => 'ticket',
        title => $title,
        description        => 'What it does.',
        problem_or_feature => 'What was wrong.',
        solution_needed    => 'What was done about it.',
        key_details        => ['What was measured.'],
        deliverables       => ['What came out of it.'],
        acceptance         => ['How it is known to be right.'],
        test_steps         => ['How it was proved.'],
        bdd                => ['Given, When, Then.'],
        atdd               => ['What somebody would check.'],
        priority           => 3,
        scope_in  => ['This'],
        scope_out => ['That'],
    );
    $tira->hierarchy_link( project => $root, parent => $parent->{ref}, child => $card->{ref} );
    $tira->checklist_add( author => 'claude', project => $root, ref => $card->{ref},
        item => 'The work itself', status => 'Done' );
    $tira->release_record(
        author => 'claude', project => $root, ref => $card->{ref},
        gate => 'suite', result => 'pass', details => 'all green',
        evidence => 'proved it', fix_version => '1.0',
    );
    return $card;
}

my $waiting = complete_card('Waiting for Michael to say it can ship');
$tira->record_move( author => 'claude', project => $root, ref => $waiting->{ref}, column => 'pending-push' );

my $tool  = File::Spec->rel2abs( File::Spec->catfile( 'tools', 'card-holes' ) );
my $skill = File::Spec->rel2abs('.');

my $stub = File::Spec->catdir( $tmp, 'bin' );
mkdir $stub or die "$stub: $!";
{
    my $path = File::Spec->catfile( $stub, 'd2' );
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} <<"PL";
#!$^X
use strict;
use warnings;
use File::Spec;
my \$command = shift \@ARGV;
\$command =~ s/\\Atira\\.//;
my \@parts = split /\\./, \$command;
my \$verb = pop \@parts;
my \$entry = \@parts
  ? File::Spec->catfile( '$skill', 'skills', \@parts, 'cli', \$verb )
  : File::Spec->catfile( '$skill', 'cli', \$verb );
exec \$^X, '-I', File::Spec->catdir('$skill','lib'), \$entry, \@ARGV;
PL
    close $fh;
    chmod 0755, $path or die "chmod: $!";
}

sub gate {
    my (@about) = @_;
    my $here = getcwd();
    chdir $tmp or die "chdir: $!";
    local $ENV{TIRA_HOME} = $root;
    local $ENV{PATH} = $stub . ':' . $ENV{PATH};
    my ( $status, $said ) = run_capturing( 'python3', $tool, @about );
    chdir $here or die "chdir back: $!";
    return ( $status, $said );
}

# --- AC1: a card below push, named by the push, is refused by name and column --

{
    my ( $status, $said ) = gate( $waiting->{ref} );
    isnt( $status, 0, 'a commit for a card still in pending-push is refused' );
    like( $said, qr/\Q$waiting->{ref}\E/, 'naming the card' );
    like( $said, qr/pending-push/, 'and the column it is actually in' );
}

# --- AC3: past the push column, the same card passes ------------------------

{
    $tira->record_move( author => 'claude', project => $root, ref => $waiting->{ref}, column => 'push' );
    my ( $status, undef ) = gate( $waiting->{ref} );
    is( $status, 0, 'moved to push, the same card is allowed' );
}

{
    $tira->record_move( author => 'claude', project => $root, ref => $waiting->{ref}, column => 'install' );
    my ( $status, undef ) = gate( $waiting->{ref} );
    is( $status, 0, 'a card in install still passes - a re-push after a fix is not blocked' );
}

{
    $tira->record_move( author => 'claude', project => $root, ref => $waiting->{ref}, column => 'verify' );
    $tira->record_move( author => 'claude', project => $root, ref => $waiting->{ref}, column => 'pending-push' );
    $tira->record_move( author => 'claude', project => $root, ref => $waiting->{ref}, column => 'push' );
    $tira->record_move( author => 'claude', project => $root, ref => $waiting->{ref}, column => 'install' );
    $tira->record_move( author => 'claude', project => $root, ref => $waiting->{ref}, column => 'done' );
    my ( $status, undef ) = gate( $waiting->{ref} );
    is( $status, 0, 'a card in done still passes' );
    $tira->record_move( author => 'claude', project => $root, ref => $waiting->{ref}, column => 'pending-push' );
}

# --- AC2: the whole-board fallback is untouched ------------------------------
#
# KD4's trap: this must never fire when nothing was named, or every board with
# a card in backlog - which is every board - refuses its own gate probe.

{
    my ( undef, $said ) = gate();
    unlike( $said, qr/pending-push/,
        'asked about the whole board, no card is refused for sitting before push' );
}

# --- AC4: a ref scraped from a commit that names no real card ----------------

{
    my ( $status, $said ) = gate('SHT-9999');
    is( $status, 0, 'a ref that matches no card on the board is not a refusal' );
    unlike( $said, qr/pending-push/, 'and not because it silently inherited another card\'s complaint' );
}

# --- and it names the card AND the column, not just one or the other --------

{
    $tira->record_move( author => 'claude', project => $root, ref => $waiting->{ref}, column => 'verify' );
    my ( undef, $said ) = gate( $waiting->{ref} );
    like( $said, qr/\Q$waiting->{ref}\E.*\bverify\b/s,
        'a card left in an earlier column - not just pending-push - is refused the same way' );
}

# --- a board with no dedicated push column is untouched ----------------------
#
# Found while checking this fix against t/235's own fixture, which builds a
# board of exactly this shape: backlog, implement, verify, done - no push
# column. Without this guard, SHIPPED_FROM falls back to the ending column
# itself, and a fully-gated card still in implement would be refused for "not
# reaching push" - the exact fault unproven()/premature() already report, not
# a missing-approval gate this board does not have.

{
    my $small_root = File::Spec->catdir( $tmp, 'small-board' );
    my $small = Tira->new( clock => sub {'2026-09-05T08:00:00Z'} );
    $small->project_new(
        name => 'No Push Column', dir => $small_root, members => ['claude'],
        columns => ['backlog, implement, verify, done'],
        sow_prefix => 'NPS', epic_prefix => 'NPE', ticket_prefix => 'NPT',
    );
    my $small_parent = $small->create_record( project => $small_root, type => 'epic',
        title => 'The release this commit belongs to' );
    my $mid = $small->create_record(
        project => $small_root, type => 'ticket',
        title => 'Still being worked, on a board with no push column',
        description => 'What it does.', problem_or_feature => 'What was wrong.',
        solution_needed => 'What was done about it.',
        key_details => ['What was measured.'], deliverables => ['What came out of it.'],
        acceptance => ['How it is known to be right.'], test_steps => ['How it was proved.'],
        bdd => ['Given, When, Then.'], atdd => ['What somebody would check.'],
        priority => 3, scope_in => ['This'], scope_out => ['That'],
    );
    $small->hierarchy_link( project => $small_root, parent => $small_parent->{ref}, child => $mid->{ref} );
    $small->checklist_add( author => 'claude', project => $small_root, ref => $mid->{ref},
        item => 'The work itself', status => 'To Do' );
    $small->record_move( author => 'claude', project => $small_root, ref => $mid->{ref}, column => 'implement' );

    my $here = getcwd();
    chdir $tmp or die "chdir: $!";
    local $ENV{TIRA_HOME} = $small_root;
    local $ENV{PATH} = $stub . ':' . $ENV{PATH};
    my ( $status, undef ) = run_capturing( 'python3', $tool, $mid->{ref} );
    chdir $here or die "chdir back: $!";
    is( $status, 0,
        'a card still in implement, on a board with no push column at all, is not refused for missing an approval gate the board does not have' );
}

done_testing;

__END__

=head1 NAME

553-the-one-gate-he-reserved-for-himself.t - card-holes refuses a push for a card below the push column

=head1 DESCRIPTION

TKT-887. C<tools/card-holes> asked whether a card was complete and never
whether it had reached the push column, so a well-formed card sitting in
C<pending-push> - the queue that exists because Michael, and only Michael,
decides what ships - shipped anyway: TKT-854 was on origin thirteen minutes
before its own card reached that column.

The new check is scoped to the refs the commits being pushed actually name,
never the whole-board fallback that runs with no argument - applying it there
would refuse every push on any board with a card in backlog, which is every
board.

=cut
