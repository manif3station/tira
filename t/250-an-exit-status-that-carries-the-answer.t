#!/usr/bin/env perl
# A scheduled job can act on what police found.
#
# Reported by developer-dashboard after being asked to run
# tira.police.outstanding every thirty minutes: it exits 0 whether the board is
# clean or carrying violations, so the job produces a log nobody opens and a
# status nobody can alarm on. That is how 154 violations accumulated there over
# two days unnoticed - 153 of them log-only, so none had reached the bridge the
# agent watches.
#
# Verified here by running rather than by reading: a board with one violation
# outstanding exits 0, exactly as a clean one does.
#
# The three-way distinction any checker needs is clean, findings, and
# could-not-look. Errors already exit 2, so only the middle one was missing.
#
# Opt-in, not a changed default: a command that starts exiting non-zero breaks
# every script that runs it today. The precedent is --if-changed, which already
# makes an exit status carry an answer on this command line.
#
# One correction to the report, which is on the card too: it says the command
# prints one record per sighting and the same card appears a dozen times. It
# does not - it returns one row per violation with a seen count, and three
# passes over the same fault still give one row. The volume is real and the
# cause is different: ten lines per record in the default output.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-17T03:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Alarmed', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ALS', epic_prefix => 'ALE', ticket_prefix => 'ALT',
);
$tira->policy_add( project => $root, rule => 'orphan-card', action => 'log-only' );
$tira->policy_add( project => $root, rule => 'card-unassigned', action => 'log-only' );

sub run {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => 'police.outstanding', tira => $tira,
                argv => [ '--store', $store, @argv ] );
        };
    };
    return ( $status, $out . $err );
}

# --- a clean board -------------------------------------------------------------

{
    my ( $status, $said ) = run( '-o', 'json' );
    is( $status, 0, 'a clean board exits zero' );

    # non-empty is the whole claim: the assertions below are about what the
    # command says, and no output would satisfy any of them.
    like( $said, qr/\S/, 'and says something' );

    my ($flagged) = run( '-o', 'json', '--exit-nonzero-if-any' );
    is( $flagged, 0, 'and exits zero with the flag too, because nothing is outstanding' );
}

# --- and a board carrying violations -------------------------------------------

{
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Nobody owns this and it has no parent' );
    $tira->police_pass( project => $root, store => $store, world => {} );

    my ( $plain, $said ) = run( '-o', 'json' );
    like( $said, qr/orphan-card/, 'the violations are there to be seen' );
    is( $plain, 0, 'and without the flag the exit status is unchanged, as it was' );

    my ($flagged) = run( '-o', 'json', '--exit-nonzero-if-any' );
    isnt( $flagged, 0,
        'while with the flag a board carrying violations exits non-zero' );
    isnt( $flagged, 2,
        'and not with the status a failure uses, which is a different answer' );
}

# --- proved by dropping the flag ------------------------------------------------
#
# The whole of this card: without it the status is the same on a board with
# violations as on one without, which is what a scheduled job cannot act on.

{
    my ($with)    = run( '-o', 'json', '--exit-nonzero-if-any' );
    my ($without) = run( '-o', 'json' );
    isnt( $with, $without,
        'the flag is what makes the status carry the answer, and nothing else does' );
}

done_testing;

__END__

=head1 NAME

250-an-exit-status-that-carries-the-answer.t - clean, findings, or could-not-look

=head1 DESCRIPTION

C<tira.police.outstanding> exited 0 whether a board was clean or carrying
violations, so a scheduled job could not alarm on it - which is how 154
violations accumulated unnoticed on the board that reported this.

C<--exit-nonzero-if-any> makes the status carry the answer, opt-in so that
nothing running today changes, and C<--by-rule> groups by rule with each
reference once.

=cut
