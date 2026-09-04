#!/usr/bin/env perl
# What the documentation says about repeated jobs, against what the board does.
#
# TKT-894, grouping TKT-878 and TKT-840. EPC-014's closing debt: the board owns
# repeated work, and the documentation has not caught up with three things that
# are already true.
#
# THE CARD'S OWN CLAIM WAS CHECKED BEFORE THIS WAS WRITTEN, because it is the
# kind of claim that goes stale. It says TKT-840's first half is done and nobody
# noticed. The live board agrees: JOB-001, JOB-002 and JOB-003 exist at
# 0 * * * *, 0 */2 * * * and 0 */3 * * *, the exact cadences it names, and they
# have been announcing on the bridge all night.
#
# WHAT IS ASSERTED HERE IS ONLY THE DOCUMENTATION, and deliberately so. Three of
# the card's seven acceptance criteria are about what the manuals say; the rest
# are operational - a monitor running, a message reaching the bridge, monitor-dead
# reporting a stopped poller - and those belong to the walkthrough, not to a .t
# file that cannot start a poller.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use Test::More;

sub slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    return $body;
}

my %doc = (
    'SKILLS.md'        => slurp('SKILLS.md'),
    'docs/commands.md' => slurp( File::Spec->catfile( 'docs', 'commands.md' ) ),
    'docs/POLICIES.md' => slurp( File::Spec->catfile( 'docs', 'POLICIES.md' ) ),
);

# non-empty is the whole claim: every assertion below greps these three, and an
# unreadable file would report every claim as missing rather than as wrong.
for my $name ( sort keys %doc ) {
    like( $doc{$name}, qr/\S/, "$name was read to check what it says" );
}

# --- the standing hunts are board jobs, and the count is right ---------------
#
# SKILLS.md says "the five standing hunts moved onto board-owned jobs". The
# board has five JOBS and three of them are hunts: JOB-001 hourly bugs, JOB-002
# two-hourly improvements, JOB-003 three-hourly doc accuracy. JOB-004 runs
# police.outstanding and JOB-005 is the is-agent-sleeping monitor - neither is a
# hunt.
#
# A number in prose that nobody can check is how this project has been wrong
# before, so the correction has to name the three rather than only fix "five".

{
    unlike( $doc{'SKILLS.md'}, qr/five standing hunts/i,
        'SKILLS.md no longer says FIVE standing hunts - the board carries five '
          . 'jobs and three hunts, and the sentence conflates them' );

    like( $doc{'SKILLS.md'}, qr/JOB-001.{0,400}JOB-002.{0,400}JOB-003/s,
        'and it names the three hunt jobs, so a reader can check the claim '
          . 'against the board instead of taking a number on trust' );
}

# --- a monitor may keep its own log, and the manual must not contradict itself

{
    # POLICIES.md already carries his later ruling in the bridge section. The
    # contradiction is in monitor-output's own entry, which quotes the EARLIER
    # instruction as an absolute - "Monitors should not have separate logs" -
    # with nothing beside it to say that was refined.
    my $policies = $doc{'docs/POLICIES.md'};

    like( $policies, qr/may keep its own log/i,
        'POLICIES.md still says a monitor may keep its own log - his ruling, '
          . 'and the half that was already right' );

    my ($entry) = $policies =~ /(\|\s*`monitor-output`.*?\|\n)/s;

    # non-empty is the whole claim: the assertion below reads this one table
    # row, and an extraction that found nothing would pass it over an empty
    # string and report a contradiction as resolved.
    like( $entry // '', qr/\S/, 'the monitor-output entry was found to read' );

    like(
        $entry // '',
        qr/own log|later|refined|keeps one|reads it himself/i,
        'AND THE ENTRY THAT QUOTES THE OLD ABSOLUTE SAYS IT WAS REFINED. It '
          . 'quotes "Monitors should not have separate logs. They all go to the '
          . 'policy bridge." as his instruction, which was true when he said it '
          . 'and is not the whole of his position now - a reader who lands on '
          . 'this row alone is told a monitor may not keep a log, which the same '
          . 'document contradicts eighty lines earlier'
    );
}

# --- the bridge drains, and the history has a home --------------------------
#
# A finding that has been acted on stops appearing, which reads as the bridge
# forgetting. It has not: the run is written down. Somebody who does not know
# that will either re-report a settled finding or assume the stream lost it.

{
    my $policies = $doc{'docs/POLICIES.md'};

    like( $policies, qr/bridge\.logs/,
        'THE BRIDGE DOCUMENTATION NAMES tira.policy.bridge.logs. The command '
          . 'exists and docs/commands.md documents it; the page that teaches '
          . 'somebody to run the bridge never mentions it, so the history is '
          . 'only findable by knowing it is there' );

    like( $policies, qr/settled.{0,200}(?:leaves|stops appearing|no longer)/is,
        'and says a settled finding LEAVES the stream, so a reader does not '
          . 'read a drained bridge as a bridge that lost something' );
}

done_testing();

__END__

=head1 NAME

518-the-documentation-still-describes-the-old-way.t - EPC-014's closing debt

=head1 WHY

TKT-894, grouping TKT-878 and TKT-840. Three things are already true of this
board and its manuals have not caught up: the standing hunts run as board-owned
jobs, a monitor may keep its own log, and the bridge drains a finding once it is
settled.

=head1 WHAT IS ASSERTED

That SKILLS.md names the three hunt jobs rather than counting five; that
POLICIES.md's C<monitor-output> entry does not leave the owner's earlier
absolute standing where the same document contradicts it eighty lines earlier;
and that the bridge documentation names C<tira.policy.bridge.logs> and says a
settled finding leaves the stream.

=head1 WHAT IS NOT ASSERTED

The card's operational half. Whether the Telegram poller runs as a board monitor,
whether a real message reaches the bridge through it, and whether C<monitor-dead>
reports it when it stops are walkthrough steps - none of them can be proved by a
test file that cannot start a poller, and pretending otherwise would be the
weaker claim wearing the stronger one's clothes.

=cut
