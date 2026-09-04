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

# --- and every other site that reads the same field --------------------------
#
# The pickup audit found a third site and MISIDENTIFIED it, which is worth
# recording rather than quietly correcting: I called Tira::Job's split "the
# runnable check". It is not. It is _same_program, the Windows liveness
# comparator, which takes a job's stored command and asks whether its program is
# the one tasklist reports. The runnable check is in Tira::CLI::Job and reads the
# first word of the ALREADY-PARSED list, so it is fixed by its caller rather than
# by itself.
#
# Both are asserted here, because "the same field parsed two ways" is the fault
# this card is about and a second reading is exactly how it comes back.

{
    require Tira::Job;

    my @words = Tira::Job::job_command_words(q{'/opt/my tools/run' --flag});
    is( scalar @words, 2,
        'a quoted program path is ONE word, not torn at the space' );
    is( $words[0], '/opt/my tools/run',
        'and the quotes grouped it rather than becoming part of it' );

    is_deeply( [ Tira::Job::job_command_words('echo plain words') ],
        [qw(echo plain words)],
        'an unquoted command still yields exactly the words it always did' );

    is_deeply( [ Tira::Job::job_command_words(undef) ], [],
        'and no command is no words rather than a list with one empty string in '
          . 'it, which is what the callers check for when they refuse a job with '
          . 'nothing to run' );

    # An unbalanced quote is a mistake somebody will make. It must not take the
    # module down: the honest failure is the command not running, which the
    # executor already reports.
    my @broken = Tira::Job::job_command_words(q{echo "unbalanced});
    ok( scalar @broken,
        'an unbalanced quote falls back to the old split rather than dying '
          . 'inside a module nobody was looking at' );
}

{
    require Tira::CLI::Job;

    ok( Tira::CLI::Job::_command_is_runnable('echo'),
        'the runnable check still passes an ordinary program - it now receives '
          . 'a word that was parsed rather than one that was cut at a space' );

    ok( !Tira::CLI::Job::_command_is_runnable('/opt/no such dir/thing'),
        'and still refuses one that is not there, given the whole path rather '
          . 'than the prefix before the first space' );
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
