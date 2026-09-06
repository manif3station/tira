#!/usr/bin/env perl
# TKT-964, split out of TKT-962's CHK-003 because that card broke the SILENCE
# around one empty answer and left the shape that produced it intact.
#
# THE SHAPE HAS TWO HALVES, and a read only misleads when it has both:
#
#   1. its board comes from discover_project when the caller names none, which
#      searches UPWARD from the working directory; and
#   2. it treats an absent file as an empty result.
#
# Together, a caller standing somewhere unexpected is answered confidently for
# whichever board lies above them - which is how four safety rules came to be
# declined against an empty jobs list on a board that had three.
#
# THREE OF THE FIVE CARRY BOTH HALVES, not five, and measuring that was the
# first half of this card. _job_read (job_list discovers), _tasklist_read
# (tasklist_list discovers), _warning_read (called as _warning_read(
# discover_project )). The other two cannot mislead: _collector_config reads
# $HOME/.developer-dashboard/config/config.json, a machine-global path with no
# board in it at all, and bridge_backlog dies without a store rather than
# guessing - "A police store is required".
#
# AND THE GUESS CAN LIVE IN THE CALLER. TKT-949's bridge bug was real while
# bridge_backlog already refused to guess: DashboardWeb resolved the store from
# the server process's own location. So the rule cannot be "a read must name
# its board".
#
# THE DECISION, recorded on CHK-002/CHK-003: the command whose answer is empty
# says on STDERR which board it was empty for, through ONE named helper at the
# CLI dispatch - not in the engine read. That placement is the half that
# satisfies this card's own refusal that a read called in a loop must not
# narrate: _tasklist_read alone has eight call sites inside Tasklist.pm.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;
use Tira::CLI;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $tira = Tira->new( clock => sub {'2026-09-06T13:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Guessed Board', dir => $root, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'GBS', epic_prefix => 'GBE', ticket_prefix => 'GBT',
    );
    return ( $tira, $root );
}

sub run_cli {
    my ( $tira, $root, $command, @argv ) = @_;
    my ( $out, $said ) = ( '', '' );
    {
        local $ENV{TIRA_HOME} = $root;
        open my $oh, '>', \$out  or die $!;
        open my $eh, '>', \$said or die $!;
        local *STDERR = $eh;
        my $old = select $oh;
        eval {
            Tira::CLI->run( command => $command, tira => $tira,
                argv => [ @argv, '-o', 'toon' ] );
            1;
        } or do { $said .= $@ // '' };
        select $old;
    }
    return ( $out, $said );
}

# --- an empty tasklist says which board it was empty for -------------------
#
# The second of the three, and the one with the most call sites reading
# through it. Same fault as the jobs list he was given: an empty answer is an
# ORDINARY answer, so nothing stops the work.

{
    my ( $tira, $root ) = board();
    my ( $out, $said ) = run_cli( $tira, $root, 'tasklist.list' );

    # non-empty is the whole claim: the check below would pass on an
    # unreadable stream's emptiness alone.
    like( $out . $said, qr/\S/, 'the command answered with something' );
    like( $out . $said, qr/Guessed Board/,
        'an empty tasklist answer NAMES the board it was empty for - the board came from the '
          . 'working directory, so a caller standing somewhere unexpected must be able to see that' );
}

# --- and an empty warning list does too ------------------------------------
#
# The third. warning_list is one line - _warning_read( discover_project ) -
# with the guess inlined into the call, which is the shape at its barest.

{
    my ( $tira, $root ) = board();
    my ( $out, $said ) = run_cli( $tira, $root, 'warning.list' );

    # non-empty is the whole claim: the check below would pass on an
    # unreadable stream's emptiness alone, exactly as in the section above.
    like( $out . $said, qr/\S/, 'the command answered with something' );
    like( $out . $said, qr/Guessed Board/,
        'an empty warnings answer names its board too, because warning_list resolves the '
          . 'board exactly the way job_list and tasklist_list do' );
}

# --- a board that HAS them says nothing about emptiness --------------------
#
# The regression that would matter most: the note belongs to the empty case
# and must not follow every ordinary listing around.

{
    my ( $tira, $root ) = board();
    $tira->tasklist_add( project => $root, text => 'a real item' );
    my ( $out, $said ) = run_cli( $tira, $root, 'tasklist.list' );

    like( $out, qr/TSK-/, 'a board with tasks still lists them' );
    # empty is what passes here, and that is the point: this board HAS tasks,
    # so nothing should have been said about emptiness at all. The listing
    # above came back on stdout in the same call, which is what proves the
    # command ran rather than the stream being unread.
    unlike( $said, qr/no tasks|empty/i,
        'and says nothing about emptiness, because it was not empty' );
}

# --- the answer itself is unchanged ----------------------------------------
#
# -o json emits the underlying payload and callers depend on the list being a
# list. A genuinely empty board is a real answer, not an error.

{
    my ( $tira, $root ) = board();
    my $tasks = $tira->tasklist_list( project => $root );
    is( ref $tasks, 'ARRAY', 'tasklist_list still returns a plain list' );
    is( scalar @{$tasks}, 0, 'and an empty board still answers with an empty one' );

    my $warnings = $tira->warning_list( project => $root );
    is( ref $warnings, 'ARRAY', 'warning_list still returns a plain list' );
    is( scalar @{$warnings}, 0, 'and an empty board still answers with an empty one' );
}

# --- one home, not three ---------------------------------------------------
#
# The registry point, and the whole reason this card exists as something other
# than three edits. job.list got this inline from TKT-962; tasklist.list and
# warning.list must not each grow their own copy of the same sentence.

{
    # ONE CALL, not one per module. Suite::cli_source walks the whole command
    # surface and ignores any argument - concatenating two calls counted every
    # sentence twice, which failed this section for a reason that had nothing
    # to do with the code under test. Caught by running it.
    my $cli = Suite::cli_source();

    # non-empty is the whole claim: the checks below would pass on an
    # unreadable layer's emptiness alone.
    like( $cli, qr/\S/, 'the command surface is there to be read' );

    my ($helper) = $cli =~ /sub \s+ (\w*empty_answer\w*|\w*names_board\w*) \b/x;
    ok( defined $helper,
        'there is ONE named helper for saying which board an empty answer was empty for, '
          . 'rather than the same sentence written out per verb' );

    my $sentence = 'the working directory resolved to';
    my $copies = () = $cli =~ /\Q$sentence\E/g;
    is( $copies, 1,
        'and the sentence itself appears exactly once in the command surface - three '
          . 'copies of one decision is the fault this card was split out to stop' );
}

# --- the reads that cannot mislead are left alone --------------------------
#
# The direction that would make this card worse than doing nothing. Two of the
# five have only the second half, and adding a note to either would be
# narrating about a board that was never guessed.

{
    my $engine = Suite::engine_source();
    # non-empty is the whole claim: every check below would pass on an
    # unreadable engine's emptiness alone, which is the whole reason the two
    # denials in this section establish their own subjects as well.
    like( $engine, qr/\S/, 'the engine source is there to be read' );

    # THE SUBJECT OF EACH DENIAL IS ESTABLISHED BY ITS CONTENT, not merely by
    # being defined. An empty capture would satisfy every unlike below for the
    # wrong reason - the fault t/147 exists for - so each is first shown to be
    # the sub it claims to be.
    my ($collector) = $engine =~ /(sub \s+ _collector_config \b .*?\n\})/xs;
    like( $collector // '', qr/_collector_config_path|\$path/,
        'the collector config read was found, and is the one that reads a path handed to it' );
    unlike( $collector // '', qr/working directory resolved/,
        'the collector config read says nothing about a board - its path is machine-global '
          . 'and has no board in it to be wrong about' );

    my ($bridge) = $engine =~ /(sub \s+ bridge_backlog \b .*?\n\})/xs;
    like( $bridge // '', qr/bridge_log_path/,
        'the bridge backlog read was found, and is the one that asks bridge_log_path for '
          . 'its file - which is what dies when no store was named' );
    unlike( $bridge // '', qr/working directory resolved/,
        'and neither does the bridge backlog, which refuses to guess a store rather than '
          . 'guessing one - the wrong board reached that panel from its CALLER' );
}

done_testing();

__END__

=head1 NAME

577-three-reads-that-answer-for-a-guessed-board.t - an empty answer says which board it was empty for, in one place

=head1 DESCRIPTION

TKT-964, split from TKT-962. Five reads in C<lib/> treat an absent file as an
empty result; three of them also resolve their board from the working
directory, which is the pair that answers a caller confidently for a board they
did not mean. C<_collector_config> reads a machine-global path with no board in
it, and C<bridge_backlog> dies without a store rather than guessing, so neither
can mislead - TKT-949's wrong board reached the bridge panel from its caller.

The command whose answer is empty says on STDERR which board it was empty for,
through one named helper at the CLI dispatch rather than in the engine read.
The placement matters as much as the note: C<_tasklist_read> has eight call
sites inside its own module, and a read that narrated would flood a single
command. The payload is unchanged, and a genuinely empty board is still a real
answer.

=cut
