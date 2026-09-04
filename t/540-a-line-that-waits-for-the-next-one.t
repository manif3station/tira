#!/usr/bin/env perl
# A monitor that prints a block gets one line through and holds the rest.
#
# TKT-930, EPC-014. Found by his question, 2026-09-04 21:31: "So why I sent
# message on TG you didn't see any notification from the policy bridge? Still
# something broken?"
#
# WHAT THE BRIDGE ACTUALLY CARRIED for his message, on his own board:
#
#   VIO-3057 JOB-006 said: NEW TG [6903] from Michael (chat 398296603):
#
# and nothing else. The line under it - the message text - never arrived. The
# board said he had spoken and not what he said, which is a worse failure than
# silence because it looks like delivery.
#
# THE LOOP ASKS THE WRONG THING WHETHER TO READ:
#
#   if ( !$watch->can_read($quiet) ) { $flush->(); next; }
#   my $line = <$handle>;
#
# select() answers about the DESCRIPTOR. readline answers about its own
# BUFFER. readline fills that buffer from the descriptor - typically the whole
# block - and returns the first line; the rest are now in Perl's memory, so the
# next can_read() reports nothing to read and the loop waits out its quiet
# window with lines in hand. They are delivered when the NEXT write wakes
# select, which is why a monitor is permanently one message behind rather than
# lossy.
#
# IT IS TKT-851's LOOP, from 5.42, and TKT-927 moved it into a shared sub
# without changing its shape. It did not matter until a monitor printed a block
# - and his Telegram poller is the one that does, so the epic's own instrument
# for hearing him was the thing hiding him.
#
# WRITTEN RED, against a real pipe rather than a fixture that hands over lines
# one at a time - which is exactly the shape that would have passed all along.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;
use Tira::CLI::Job::Feeder;

my ( $tira, $root );
{
    my $tmp = tempdir( CLEANUP => 1 );
    $root = File::Spec->catdir( $tmp, 'board' );
    $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Block', dir => $root,
        members => ['claude'], columns => ['backlog, done'],
        sow_prefix => 'BKS', epic_prefix => 'BKE', ticket_prefix => 'BKT',
    );
}

# Reading is what is under test, so the handle has to be a real pipe with a
# real writer on the other end. An in-memory filehandle would never make select
# and readline disagree, and would pass against the broken loop.
#
# AND THE WRITER MUST STAY OPEN, which the first version of this file got
# wrong. Closing it after the block makes select report readable for ever at
# end of file, so the loop reads every line without waiting - and every
# behavioural assertion below passed against the broken code. That is the same
# fault as t/535's first version: the fixture did not reproduce the condition.
#
# A monitor's pipe is never at end of file. tail -F holds it open, says its
# piece, and says nothing more - which is exactly when the held lines become
# invisible. So the writer is a CHILD that writes and then waits, and the read
# is bounded by an alarm rather than by end of input.
sub feed_through {
    my ( $id, @writes ) = @_;

    pipe my $reader, my $writer or die "pipe: $!";

    my $child = fork();
    die "fork: $!" if !defined $child;
    if ( !$child ) {
        close $reader;
        $writer->autoflush(1);
        print {$writer} $_ for @writes;
        sleep 30;    # the pipe stays open, as a monitor's does
        exit 0;
    }
    close $writer;

    # Long enough for two quiet windows, so a flush has certainly happened and
    # the loop has certainly gone round again - which is the moment the held
    # lines are invisible.
    eval {
        local $SIG{ALRM} = sub { die "read window over\n" };
        alarm 3;
        Tira::CLI::Job::Feeder::feed_from_handle( $tira, { project => $root },
            $id, $reader, 1, 25 );
        alarm 0;
        1;
    } or alarm 0;

    kill 'TERM', $child;
    waitpid $child, 0;
    close $reader;

    my ($job) = grep { ( $_->{id} // '' ) eq $id }
      @{ $tira->job_list( project => $root ) };
    return $job;
}

# The end-of-input case needs the opposite fixture: a writer that CLOSES, since
# what is asserted there is what happens when a monitor stops mid-sentence.
sub feed_until_closed {
    my ( $id, @writes ) = @_;

    pipe my $reader, my $writer or die "pipe: $!";
    $writer->autoflush(1);
    print {$writer} $_ for @writes;
    close $writer;

    Tira::CLI::Job::Feeder::feed_from_handle( $tira, { project => $root },
        $id, $reader, 1, 25 );
    close $reader;

    my ($job) = grep { ( $_->{id} // '' ) eq $id }
      @{ $tira->job_list( project => $root ) };
    return $job;
}

# --- a block written in one go -------------------------------------------------

{
    my $job = $tira->job_add( project => $root, schedule => 'monitor',
        command => 'a-poller-that-speaks-in-blocks', author => 'claude' );

    my $after = feed_through( $job->{id},
        "NEW TG [6903] from Michael (chat 398296603):\n"
          . "  Is that the log file the TG poller writing to?\n"
          . "  reply hint line\n" );

    is( scalar @{ $after->{output} || [] }, 3,
        'EVERY LINE OF A BLOCK IS RECORDED. One write, three lines, and today '
          . 'only the first arrives: readline drains the pipe into its own '
          . 'buffer, select then says there is nothing to read, and the rest '
          . 'wait for the next write. That is why the bridge announced that he '
          . 'had spoken without saying what he said' );

    is( ( $after->{output} || [] )->[1],
        '  Is that the log file the TG poller writing to?',
        'and the second line is the one he actually sent - the text, not the '
          . 'header' );

    is( scalar @{ $after->{recent} || [] }, 3,
        'and the card holds all three too, since the tail a monitor shows is '
          . 'fed from the same call' );
}

# --- a line split across two writes -------------------------------------------
#
# The other half of reading a descriptor rather than a line: a write can end
# mid-line, and a fix that split on whatever arrived would deliver half a line
# now and half later. The partial tail has to be kept.

{
    my $job = $tira->job_add( project => $root, schedule => 'monitor',
        command => 'a-poller-that-writes-in-halves', author => 'claude' );

    my $after = feed_through( $job->{id}, "a line in ", "two halves\n" );

    is_deeply( $after->{output}, ['a line in two halves'],
        'A LINE SPLIT ACROSS TWO WRITES ARRIVES ONCE AND WHOLE. This is what a '
          . 'buffer of the loop\'s own is for, and the reason the fix is not '
          . 'simply "read everything and split on newline"' );
}

# --- and a monitor that never finishes its last line ---------------------------
#
# The end of input with a partial line held. It has to go in rather than be
# dropped, because a monitor killed mid-sentence has still said something -
# and dropping it is the silent truncation this whole epic exists to end.

{
    my $job = $tira->job_add( project => $root, schedule => 'monitor',
        command => 'a-poller-cut-off', author => 'claude' );

    my $after = feed_until_closed( $job->{id}, "said this much and then stopped" );

    is_deeply( $after->{output}, ['said this much and then stopped'],
        'a last line with no newline is still recorded when the input ends, '
          . 'because a monitor cut off mid-sentence has still spoken' );
}

# --- the bounded quiet survives ------------------------------------------------
#
# TKT-851's reason for the loop, and the thing a rewrite is most likely to take
# with it: the flush after a silent window is why a monitor that speaks once an
# hour is heard within seconds rather than after twenty-five lines. Source-read
# through Suite, per t/486.

my $source = do {
    require Suite;
    Suite::cli_source();
};

my ($loop) = $source =~ /(sub \s feed_from_handle .*? \n \} )/xs;

ok( defined $loop && length $loop, 'the reader was found to read' );

like( $loop // '', qr/can_read\(\s*\$quiet/,
    'the bounded wait is still there - a monitor that speaks rarely is heard '
      . 'within seconds, which is what TKT-851 put it there for' );

like( $loop // '', qr/\$flush->\(\)/,
    'and so is the flush on that timeout, the half that makes the bound useful '
      . 'rather than merely short' );

like( $loop // '', qr/sysread/,
    'AND THE READ IS OF THE DESCRIPTOR, not of a line. select can only answer '
      . 'about the descriptor, so that is the only thing the loop may ask it '
      . 'about - the lines come out of a buffer the loop owns' );

done_testing();

__END__

=head1 NAME

540-a-line-that-waits-for-the-next-one.t - the feeder reads one line per wake-up

=head1 WHY

TKT-930. C<feed_from_handle> waits on C<select> and then reads B<one line> with
C<readline>. C<readline> fills its own buffer from the descriptor, so after the
first line the remainder sits in Perl's memory where C<select> cannot see it,
and the loop waits out its quiet window holding lines it has already read. They
are delivered only when the next write wakes C<select>.

Measured on his own board: a Telegram message reached the police bridge as its
header line alone, with the text he sent absent - the board saying he had spoken
without saying what he said.

=head1 WHAT IS ASSERTED

Through a B<real pipe>, because an in-memory handle never makes C<select> and
C<readline> disagree and would pass against the broken loop: that a three-line
block written once is recorded in full; that a line split across two writes
arrives once and whole; and that a final line with no newline is still recorded.

Then, by source, that TKT-851's bounded quiet and its flush both survive, and
that the read is of the descriptor rather than of a line.

=cut
