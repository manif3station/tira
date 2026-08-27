#!/usr/bin/env perl
# Onboarding reports failure and leaves a whole project behind it.
#
# The dispatch shared by project.new and onboard runs project_new to
# completion first - which returns only once the project, its people, its
# boards and every column are written to disk - and only afterwards calls
# project_mode with whatever --mode was given. project_mode refuses anything
# but 'single' or 'chain', so an invalid value dies at a point where there is
# nothing left to undo: the caller sees a nonzero exit and an error, and a
# real project now exists that nothing told them about.
#
# Reproduced rather than reasoned about, and the repro widened the card, which
# had named tira.onboard and the browser form only:
#
#   d2 tira.project.new --dir DIR ... --mode nonsense
#   error: A project is worked by a single agent or by a chain of them
#   ls -a DIR  ->  .  ..  .tira
#
# Which paths can actually reach it matters, because the first version of this
# test asserted the same thing about `onboard` and passed for the wrong
# reason. onboard ALWAYS prompts unless -o browser is given: with no input it
# reaches end of stream and aborts before the dispatch, so it refused an
# invalid --mode without ever having looked at it. That is a vacuous
# assertion, not a passing one. The reachable paths are project.new's --mode
# flag, and the browser form, which since TKT-553 renders mode as a plain text
# input whose options are only a hint and which calls back into this same
# dispatch. Both go through the branch tested here.
#
# The wizard's own path is deliberately NOT asserted here. Driving it means
# feeding a scripted answer stream through the injected input seam, and an
# assertion that merely survives that is the same trap again - it would pass
# whether or not the wizard validated anything. It is already covered where
# it belongs, by the wizard's own tests, and this fix does not touch it.
#
# What makes this worth a card rather than a shrug is the shape of the
# failure, not its rarity: "it failed" and "it half worked" are different
# facts, and only one of them tells you to go and look at the directory. The
# next attempt then meets a project that should not be there. TKT-562.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-27T09:00:00Z'} );

sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_AUTHOR} = 'claude';
            Tira::CLI->run( command => $command, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

sub onboarding_argv {
    my ($dir) = @_;
    return (
        '--dir',           $dir,     '--name',        'Probe',
        '--members',       'claude', '--columns',     'Backlog, Done',
        '--sow-prefix',    'PBS',    '--epic-prefix', 'PBE',
        '--ticket-prefix', 'PBT',
    );
}

# --- the refusal has to come before anything is written ----------------------

{
    my $dir = File::Spec->catdir( $tmp, 'bad-mode' );
    my ( $status, $said ) = run( 'project.new', onboarding_argv($dir), '--mode', 'nonsense' );

    isnt( $status, 0, 'project.new refuses an invalid --mode' );

    # The whole point of the card. A refusal that leaves the thing behind is
    # not a refusal, and this is the assertion that fails before the fix.
    ok( !-e File::Spec->catdir( $dir, '.tira' ),
        'and created no project, having been going to fail' );

    # Naming the option is what the old message could not do, because it came
    # from project_mode, which has no idea it was reached through a flag.
    # Asserting on 'single'/'chain' alone would pass before the fix too - the
    # old wording contains both words - so it would prove nothing.
    like( $said, qr/--mode/, 'naming the option that was wrong' );
    like( $said, qr/single/, 'and the values it will take' );
    like( $said, qr/chain/,  'both of them' );
}

# --- the valid values still work, so this is a guard and not a wall ----------

for my $mode (qw(single chain)) {
    my $dir = File::Spec->catdir( $tmp, "good-$mode" );
    my ($status) = run( 'project.new', onboarding_argv($dir), '--mode', $mode );

    is( $status, 0, "project.new still accepts --mode $mode" );
    ok( -e File::Spec->catdir( $dir, '.tira' ), "and the project exists for $mode" );
    is( $tira->project_mode( project => $dir ), $mode,
        "and the mode actually landed as $mode" );
}

# --- omitting it entirely is untouched, which is every board that exists -----

{
    my $dir = File::Spec->catdir( $tmp, 'no-mode' );
    my ($status) = run( 'project.new', onboarding_argv($dir) );

    is( $status, 0, 'project.new with no --mode at all still works' );
    is( $tira->project_mode( project => $dir ), undef,
        'and leaves the mode unset, the way every existing board is' );
}

done_testing;

__END__

=head1 NAME

404-a-project-that-exists-after-it-failed.t - onboarding that fails after creating

=head1 DESCRIPTION

The C<project.new>/C<onboard> dispatch writes the entire project before it
validates C<--mode>, so an invalid value produces a failed command and a real
project on disk at the same time. These tests assert the refusal happens first
and creates nothing, that the message names the option and both values it
accepts, and that valid modes and an absent mode are unaffected.

=cut
