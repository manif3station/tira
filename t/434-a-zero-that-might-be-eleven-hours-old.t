#!/usr/bin/env perl
# "No violations outstanding" is printed the same way whether the pass was ten
# seconds ago or eleven hours ago.
#
# The timestamp IS there - "No violations outstanding, as of the pass at <ts>" -
# and it is never judged. So the sentence a reader is meant to trust comes first
# and the thing that would undermine it comes second, in a format nobody does
# arithmetic on.
#
# NOT HYPOTHETICAL, AND THAT IS WHY THIS FILE EXISTS. On 2026-08-29 the zenandi
# board answered "No violations outstanding, as of the pass at
# 2026-08-29T03:38:41+0100" on every thirty-minute run for eleven hours, because
# nothing had run a pass since 03:38. Two cards were filed off the back of it -
# TKT-740, which asked only that a fresh zero be distinguishable from a cached
# one, and TKT-744, which found a card an hour past its declared card-duration
# age with silence on the channel that exists to say so. The person reading it
# could not tell, and did the arithmetic by hand across ten invocations.
#
# WHAT THIS FILE DOES NOT COVER, deliberately: the -o json half. An empty bare
# list has nowhere to put a pass time, and fixing that changes the payload shape
# that other projects' clear-violations loops pipe and index - a decision whose
# cost lands on his other boards, asked as Q-096 and not made here. The human
# output needs no such decision, so it is tested now rather than held hostage.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-29T03:38:41+0100';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Stale', dir => $root, members => ['claude'],
    columns    => ['backlog, implement, done'],
    sow_prefix => 'SS', epic_prefix => 'SE', ticket_prefix => 'ST',
);

sub outstanding {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => 'police.outstanding', tira => $tira,
            argv => [ '--store', $store, @argv ] );
    };
    return ( $status, $out . $err );
}

# --- a board nobody has policed still says so ---------------------------------
#
# Green today and must stay green: this is the card's fourth acceptance
# criterion, and it is the case a careless staleness check breaks first. A board
# with no pass at all has no age to judge, and "the pass is very old" is the
# wrong sentence for "there has never been one".

{
    my ( $status, $said ) = outstanding();
    is( $status, 0, 'asking a board nobody has policed is not an error' );
    like( $said, qr/never|no pass|not been/i,
        'and it says nothing has been checked, rather than reporting a clean board' );
}

$tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );
$tira->police_pass( project => $root, store => $store, world => {} );

# --- a fresh pass reads exactly as it always has ------------------------------
#
# The card's fifth acceptance criterion, and the control for everything below.
# A warning that fires on a healthy board is worse than no warning: it is the
# shape that teaches a reader to skip the channel, which is what card-duration
# did on this very board when it fired 63 times with no action available.

$now = '2026-08-29T03:38:51+0100';    # ten seconds later

{
    my ( undef, $said ) = outstanding();
    like( $said, qr/no violations outstanding/i,
        'ten seconds after a pass, a clean board still leads with the reassurance' );
    unlike( $said, qr/stale|stopped|may not|hours ago|no longer/i,
        'and says nothing about staleness, because there is none' );
}

# --- eleven hours later, the same zero means something else -------------------
#
# THE CARD. Same board, same empty result, same command - and the only thing
# that changed is that nothing has looked since. The assertion is about ORDER as
# much as content: the card asks for the staleness "before any reassurance",
# because a reader who has already read "No violations outstanding" has stopped
# reading.

$now = '2026-08-29T14:41:50+0100';    # the reading he actually took

{
    my ( undef, $said ) = outstanding();

    like( $said, qr/stale|stopped|may not|hours|no longer/i,
        'eleven hours after the last pass, a clean board says the detector may '
          . 'have stopped rather than reporting silence as health' );

    my $warning     = $said =~ /(stale|stopped|may not|hours|no longer)/i ? $-[0] : -1;
    my $reassurance = $said =~ /no violations outstanding/i               ? $-[0] : -1;
    ok( $warning >= 0 && ( $reassurance < 0 || $warning < $reassurance ),
        'and says it BEFORE any reassurance - a reader who has read "no '
          . 'violations outstanding" has already stopped reading' );

    like( $said, qr/03:38/,
        'while still naming the pass it is judging, so the reader can check it' );
}

# --- and the same judgement when there ARE findings ---------------------------
#
# The non-zero case is the one nobody thinks about, and it is worse rather than
# better: "5 outstanding, as of the pass at <ts>" reads as a live count, so a
# reader acts on a list that may describe a board eleven hours gone. The card
# asks for both outputs, not the empty one.

$now = '2026-08-29T03:38:41+0100';
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'an orphan, to make the list non-empty', priority => 3 );
$tira->record_move( author => 'claude', project => $root, ref => $card->{ref},
    column => 'implement' );
$tira->police_pass( project => $root, store => $store, world => {} );
$now = '2026-08-29T14:41:50+0100';

{
    my ( undef, $said ) = outstanding();
    like( $said, qr/outstanding/i, 'a board with findings still reports them' );
    like( $said, qr/stale|stopped|may not|hours|no longer/i,
        'and a stale pass is called out for a non-empty answer too - a count '
          . 'from eleven hours ago is not a live count' );
}

done_testing();

__END__

=head1 NAME

t/434-a-zero-that-might-be-eleven-hours-old.t - C<police.outstanding> must judge
the age of the pass it is reporting, not merely print it

=head1 DESCRIPTION

The command already names the pass time. It never says whether that time is any
good, so a clean board and a stopped detector print the same reassuring
sentence, and the timestamp that distinguishes them arrives after it.

Measured on 2026-08-29: the zenandi board answered C<No violations outstanding,
as of the pass at 2026-08-29T03:38:41+0100> on every thirty-minute run for
eleven hours, because nothing had run a pass since 03:38. A C<card-duration>
policy went an hour past its age in that silence.

=head2 What is asserted, and in what order

Four things, and the order assertion is the point rather than a nicety. The
staleness must appear I<before> the reassurance, because a reader who has
already read "No violations outstanding" has stopped reading.

The fresh-pass and never-policed cases are green before this card and must stay
green. A warning that fires on a healthy board teaches a reader to skip the
channel it arrives on, which is the failure C<card-duration> demonstrated on
this board when it fired sixty-three times with no action available.

=head2 What this file leaves alone

The C<-o json> half. An empty bare list has nowhere to carry a pass time, and
giving it one changes the payload shape that other projects' clear-violations
loops pipe and index. That decision is Q-096 on the card, and it is not this
file's to make.

=cut
