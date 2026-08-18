#!/usr/bin/env perl
# A clean board does not signal that something is wrong.
#
# --exit-nonzero-if-any exists so a script can ask "did this find anything" and
# branch on the answer. 2.62 gave tira.police.outstanding a summary for its
# default output - prose rows saying how many are outstanding and as of when -
# while -o json kept returning the bare list. The exit status was taken from the
# RENDERED ROWS, so a clean board returned one row of prose and the flag read it
# as one finding:
#
#   d2 tira.police.outstanding --exit-nonzero-if-any          -> exit 1   WRONG
#   d2 tira.police.outstanding --exit-nonzero-if-any -o json  -> exit 0   correct
#
# preceded in the same second by "No violations outstanding, as of the pass at
# 2026-08-18T15:01:56+0100". The command said nothing was wrong and signalled
# that something was.
#
# That regression is mine, and so is the reason it shipped: t/268 asserted the
# summary's SENTENCE and never its exit status, because I was testing the feature
# I had just written rather than the contract the command already had. The flag
# is the entire reason that command exists in a script.
#
# So the fix is general rather than a patch to the summary. A command that knows
# how many findings it has says so, and the exit logic prefers that over counting
# rows - otherwise the next command to group or summarise its output falls into
# the same hole, and TKT-291 asks for exactly that on this same command.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-18T16:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Exit', dir => $root, members => ['claude'], agent => 'claude',
    columns => ['backlog, implement, done'],
    sow_prefix => 'EXS', epic_prefix => 'EXE', ticket_prefix => 'EXT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

sub status_of {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        $status = Tira::CLI->run( command => 'police.outstanding', tira => $tira,
            argv => [ '--store', $store, @argv ] );
    }
    return ( $status, $out . $err );
}

# --- a clean board ---------------------------------------------------------------------
#
# Both output modes, because the whole defect was that they disagreed - and a
# test that checked only one would have passed while the command lied to every
# script reading the other.

{
    # A ledger with a recorded pass, not a board that has never been touched -
    # otherwise the summary says "never been policed" rather than "no
    # violations outstanding", and the text assertion below would be checking
    # the wrong sentence for the wrong reason. And a board with no policy
    # declared never writes last_pass at all - police_pass short-circuits
    # before touching the ledger.
    $tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );
    $tira->police_pass( project => $root, store => $store );

    my ( $default, $default_text ) = status_of('--exit-nonzero-if-any');
    my ($json) = status_of( '--exit-nonzero-if-any', '-o', 'json' );

    is( $json,    0, 'a clean board exits 0 in json, as it always did' );
    is( $default, 0, 'and now exits 0 in the default output too' );
    like( $default_text, qr/no violations outstanding/i,
        'while still saying so in words - the summary is not what was wrong' );
}

# --- and the flag still fires when there IS something --------------------------------
#
# The half that stops this being fixed by making the flag always return 0, which
# would pass the block above and destroy the feature.

{
    my $card = $tira->create_record(
        project => $root, type => 'ticket', title => 'Unparented on purpose',
        description => 'To make orphan-card fire', priority => 3,
    );
    $tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );
    $tira->police_pass( project => $root, store => $store );

    my $open = $tira->police_outstanding( project => $root, store => $store );
    ok( scalar @{$open}, 'the board now has a finding, so the next assertions mean something' )
      or diag('no finding was raised - the rest of this block would pass vacuously');

    my ( $default, $default_text ) = status_of('--exit-nonzero-if-any');
    my ($json) = status_of( '--exit-nonzero-if-any', '-o', 'json' );

    is( $json,    1, 'a board with findings exits 1 in json' );
    is( $default, 1, 'and in the default output' );
    like( $default_text, qr/\Q$card->{ref}\E/, 'and the summary names the card' );
}

# --- without the flag, nothing changes ---------------------------------------------------

{
    my ($default) = status_of();
    is( $default, 0, 'without the flag a board with findings still exits 0' );
}

# --- and not by emptying the summary ------------------------------------------------------
#
# Everything above passes against a command that returns nothing at all on a
# clean board - which would be a way to make the row count come out right and
# would also delete the answer the summary exists to give. So the two are
# asserted together: the clean board still says something in words AND exits 0.
# Only a status that stopped being derived from the rows can satisfy both.

{
    # Its own board, not the one above - that one has a finding on it by now, and
    # a block asserting "clean board exits 0" that silently runs against a dirty
    # one is a test passing for the wrong reason. Written after making exactly
    # that mistake here.
    my $fresh = File::Spec->catdir( $tmp, 'clean' );
    my $second = Tira->new( clock => sub {'2026-08-18T16:00:00Z'} );
    $second->project_new(
        name => 'Clean', dir => $fresh, members => ['claude'], agent => 'claude',
        columns => ['backlog, implement, done'],
        sow_prefix => 'CNS', epic_prefix => 'CNE', ticket_prefix => 'CNT',
    );
    my $fresh_store = File::Spec->catdir( $tmp, 'clean-police-state' );

    # A board with no policy declared never writes last_pass at all - police_pass
    # short-circuits before touching the ledger - so "as of the pass at" would
    # never appear regardless of this fix. At least one rule has to be watching.
    $second->policy_add( project => $fresh, rule => 'orphan-card', action => 'log-only' );
    $second->police_pass( project => $fresh, store => $fresh_store );
    is( scalar @{ $second->police_outstanding( project => $fresh, store => $fresh_store ) }, 0,
        'the second board really is clean, which the rest of this block assumes' );

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $fresh;
        $status = Tira::CLI->run( command => 'police.outstanding',
            tira => $second, argv => [ '--store', $fresh_store, '--exit-nonzero-if-any' ] );
    }
    my $text = $out . $err;
    is( $status, 0, 'the clean board exits 0' );
    ok( length $text, 'and still answers in words rather than falling silent' );
    like( $text, qr/as of the pass at/,
        'including when the answer was taken, which is the 2.62 feature this must not undo' );
}

done_testing;

__END__

=head1 NAME

273-a-clean-board-exits-zero.t - TKT-385

=head1 DESCRIPTION

C<--exit-nonzero-if-any> took its answer from the rendered rows, so the summary
added in 2.62 made a clean board exit 1 on the output a human reads while still
exiting 0 on the one a script reads. The count of findings is now stated by the
command that knows it, so summarising, grouping or adding a heading cannot move
the signal again.

=cut
