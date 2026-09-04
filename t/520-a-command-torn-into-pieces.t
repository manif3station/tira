#!/usr/bin/env perl
# An argument with a space in it, in a job command.
#
# TKT-898, EPC-014. A job command is split on whitespace and nothing understands
# quotes, so any argument containing a space is silently torn into pieces - and
# the job runs, exits 0, and does the wrong thing.
#
#   stored : d2 tira.comment.add --ref TKT-1 --text "two words"
#   runs as: [d2] [tira.comment.add] [--ref] [TKT-1] [--text] ["two] [words"]
#
# The quote marks become part of the arguments rather than grouping them, and
# nothing reports a problem because nothing failed.
#
# THE CONFUSION THIS FIXES, from the card's KD4: "no shell" was treated as "no
# quoting". A shell does TWO things - it GROUPS arguments and it INTERPRETS
# metacharacters. TKT-851 removed both when it only needed to remove the second,
# and proved the removal against six injection attempts. Grouping has to come
# back; interpretation must not.
#
# So every assertion here comes in a pair: something that must now GROUP, and
# something that must still stay LITERAL. A fix that satisfied only the first
# half would be a shell, and would undo the card this one depends on.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;
use Tira::CLI::Police;

# --- quotes GROUP ------------------------------------------------------------
#
# run_due_job is the site that actually runs a command, so these are behavioural
# rather than a reading of the source: the assertion is what the process printed.

{
    my $result = Tira::CLI::Police::run_due_job(
        job => { mode => 'command', command => 'echo "two words"', run_timeout => 10 } );

    # non-empty is the whole claim: the assertions below read this result, and a
    # command that never ran would fail them for a reason that is not this card.
    ok( ref $result eq 'HASH', 'the job ran and there is a result to read' );

    my $output = ( $result || {} )->{output} // '';
    $output =~ s/\s+\z//;

    is( $output, 'two words',
        'AN ARGUMENT WITH A SPACE SURVIVES AS ONE ARGUMENT, and the quote marks '
          . 'are not in the output - they grouped it rather than becoming part '
          . 'of it. Today this prints "two words" WITH the quotes, which is the '
          . 'whole complaint: it exits 0 and does the wrong thing quietly' );

    is( ( $result || {} )->{status}, 0, 'and it succeeded, as it always did' );
}

# A cron expression as an argument - his own example, and the one that makes a
# job that files a job impossible today: five fields become five arguments.

{
    my $result = Tira::CLI::Police::run_due_job(
        job => { mode => 'command', command => q{echo '0 * * * *'}, run_timeout => 10 } );

    my $output = ( ( $result || {} )->{output} // '' );
    $output =~ s/\s+\z//;

    is( $output, '0 * * * *',
        'a cron expression passed as an argument arrives as ONE argument - '
          . 'single quotes group as well as double, since a person writing a '
          . 'schedule will reach for whichever is to hand' );
}

# --- and metacharacters stay LITERAL ----------------------------------------
#
# TKT-851's guarantee, which this card must not spend. Each of these is a thing
# a shell would ACT on; every one has to come back as text.

{
    # THE ASSERTION COMPARES THE WHOLE OUTPUT, and the first version of this
    # block did not - it looked for the absence of a marker word, and the marker
    # is INSIDE the literal text. `echo PWNED` contains "PWNED" whether it ran or
    # not, so five of these failed while the code was behaving correctly. An
    # assertion that cannot tell the two apart is worth less than none.
    #
    # Comparing the exact output separates them cleanly: literal means the
    # metacharacters come back; executed means they are gone and their effect is
    # there instead.
    my %literal = (
        'a semicolon'    => [ 'echo "a; echo RAN"',      'a; echo RAN' ],
        'a backtick'     => [ 'echo "a `echo RAN`"',     'a `echo RAN`' ],
        'a dollar-paren' => [ 'echo "a $(echo RAN)"',    'a $(echo RAN)' ],
        'a pipe'         => [ 'echo "a | echo RAN"',     'a | echo RAN' ],
        'an ampersand'   => [ 'echo "a && echo RAN"',    'a && echo RAN' ],
        'a redirect'     => [ 'echo "a > /tmp/tira-pwned-520"', 'a > /tmp/tira-pwned-520' ],
    );

    for my $what ( sort keys %literal ) {
        my ( $command, $expected ) = @{ $literal{$what} };
        my $result = Tira::CLI::Police::run_due_job(
            job => { mode => 'command', command => $command, run_timeout => 10 } );

        my $output = ( ( $result || {} )->{output} // '' );
        $output =~ s/\s+\z//;

        is( $output, $expected,
            "$what comes back AS TEXT - the characters are in the output, which "
              . 'is what "no shell" means. TKT-851 removed the shell and proved '
              . 'it against six attempts like this; restoring grouping must not '
              . 'restore interpretation' );
    }

    ok( !-e '/tmp/tira-pwned-520',
        'and the redirect wrote no file - the strongest form of the same claim, '
          . 'since an output check alone would pass on a command whose effect '
          . 'happened somewhere other than its own output' );
}

# --- an unquoted command is unchanged ---------------------------------------
#
# The fix must not alter the ordinary case, which is nearly every job on the
# board.

{
    my $result = Tira::CLI::Police::run_due_job(
        job => { mode => 'command', command => 'echo plain words here', run_timeout => 10 } );

    my $output = ( ( $result || {} )->{output} // '' );
    $output =~ s/\s+\z//;

    is( $output, 'plain words here',
        'an unquoted command splits exactly as it does today - three arguments, '
          . 'printed with single spaces between them' );
}

# --- the runnable check reads the same command the same way ------------------
#
# The third site, found in the pickup audit rather than named on the card:
# Tira::Job takes the FIRST WORD of a command to ask whether the system can run
# it. Split the same way, a quoted program path with a space in it is torn there
# too, and the check then asks about a program nobody named.

{
    require Tira::Job;

    ok( !Tira::Job::_command_is_runnable(q{'/opt/no such dir/thing'}),
        'a quoted program path is judged as ONE program - it is not runnable '
          . 'here and should say so, rather than being torn at the space and '
          . 'judged on a prefix nobody wrote' );

    ok( Tira::Job::_command_is_runnable('echo hello'),
        'and an ordinary command is still runnable, so the check has not simply '
          . 'started refusing everything' );
}

done_testing();

__END__

=head1 NAME

520-a-command-torn-into-pieces.t - quoting in a job command

=head1 WHY

TKT-898. A job command is split on whitespace with no understanding of quotes,
so C<--text "two words"> runs as three arguments and the job exits 0 having done
the wrong thing.

=head1 WHAT IS ASSERTED

In pairs, deliberately. That quotes GROUP - an argument with a space survives,
in both quote styles - and that metacharacters stay LITERAL: a semicolon, a
backtick, a C<$(...)>, a pipe, an ampersand and a redirect all come back as
text, and the redirect writes no file.

That pairing is the point. TKT-851 removed the shell and proved it against six
injection attempts; a fix that restored grouping by restoring a shell would
satisfy half this file and undo the card it depends on.

Also that an unquoted command is unchanged, and that the runnable check - a
third site, found when this card was picked up rather than named on it - reads a
quoted program path as one program.

=cut
