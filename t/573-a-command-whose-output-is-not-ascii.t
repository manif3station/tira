#!/usr/bin/env perl
# TKT-953. His report, captioned 亂碼？- a job's output panel rendering a shrug
# emoji as a run of Latin-1 characters.
#
# THE FAULT, found by elimination and then by execution. Two functions in this
# codebase read a child process's output. They disagree:
#
#   Tira::CLI::Job::Feeder::feed_from_handle  - reads with sysread, then
#       Encode::decode('UTF-8', $line, FB_QUIET) on every line. Since TKT-932
#       (5.58), which put it there for exactly this class of fault. PROVEN
#       CLEAN by running it: bytes in, codepoint U+21B3 stored.
#
#   Tira::CLI::Police::run_due_job           - reads with sysread and does not
#       decode at all. Its output goes to run_due_commands (TKT-944, 5.81),
#       which hands it to job_feed.
#
# And the engine does not round-trip byte strings: a byte string written into a
# field reads back as U+00E2 U+0086 U+00B3, because the JSON writer is in utf8
# mode and encodes a byte-held-as-character a second time. So a command job
# whose output is not pure ASCII stores mojibake.
#
# ONE DECISION IN TWO PLACES, which is the shape t/566 exists to catch and does
# not yet carry an entry for. The fix belongs where the bytes are read - the
# same place the feeder decodes - and NOT in a compensating decode further
# down, which would look right and be wrong.
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
use Tira::CLI::Police;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $now  = '2026-09-06T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Not Ascii', dir => $root, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'NAS', epic_prefix => 'NAE', ticket_prefix => 'NAT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    $tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ), \$now );
}

sub run_pass {
    my ( $tira, $root, $store ) = @_;
    return $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
}

sub recent_of {
    my ( $tira, $root ) = @_;
    my ($job) = grep { $_->{id} eq 'JOB-001' } @{ $tira->job_list( project => $root ) };
    return @{ $job->{recent} || [] };
}

# --- a command job's non-ASCII output is stored as characters --------------
#
# The whole card. The command prints one UTF-8 arrow; what lands on the job
# must be that character, not the three bytes of it held apart.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *',
        command => '/bin/sh -c "printf \'\\342\\206\\263 arrow\\n\'"' );

    ${$clock} = '2026-09-06T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );
    Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    my ($line) = recent_of( $tira, $root );
    $line //= '';
    # non-empty is the whole claim: every check below would pass on an empty
    # line for the wrong reason - the command not having run at all.
    like( $line, qr/\S/, 'the command ran and its output reached the job' );

    my @cp = map { ord } split //, $line;
    is( $cp[0], 0x21B3,
        'the arrow is stored as one character (U+21B3), not as the three bytes of its '
          . 'UTF-8 encoding held as separate characters - which is what the owner saw' );
    is( scalar( grep { $_ == 0x00E2 || $_ == 0x0086 } @cp ), 0,
        'and none of the Latin-1 fragments of that encoding appears in the stored line' );
}

# --- plain ASCII output is unchanged ---------------------------------------
#
# The direction a careless fix breaks. Most command output is ASCII and must
# come through exactly as before.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *',
        command => '/bin/sh -c "echo plain-ascii-output"' );

    ${$clock} = '2026-09-06T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );
    Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    my ($line) = recent_of( $tira, $root );
    is( $line, 'plain-ascii-output', "an ASCII command's output is untouched" );
}

# --- the two readers agree ------------------------------------------------
#
# The registry point, and the reason this card is not just a decode added in
# one spot. Two functions read a child process's output; both must decode it,
# or the next one written will pick whichever it happened to read first.

{
    # TKT-1043 lifted run_due_job's real body into Tira::CLI::Police::Jobs -
    # 'Jobs.pm' alone is ambiguous with Tira::CLI::Browser::Jobs (TKT-1042),
    # so the path is qualified.
    my $police = Suite::cli_source('Police/Jobs.pm');
    my $feeder = Suite::cli_source('Job/Feeder.pm');

    # non-empty is the whole claim: the checks below would pass on unreadable
    # files' emptiness alone.
    like( $police, qr/\S/, 'the police source is there to be read' );
    like( $feeder, qr/\S/, 'the feeder source is there to be read' );

    my ($reader) = $police =~ /(sub \s+ run_due_job \b .*?\n\})/xs;
    ok( defined $reader, 'run_due_job was found, to read how it handles what it reads' );
    like( $reader // '', qr/Encode::decode|decode_utf8/,
        'run_due_job decodes the child output it reads, as feed_from_handle already does - '
          . 'two readers of the same kind of stream must not disagree about this' );
    like( $feeder, qr/Encode::decode/,
        'and the feeder still decodes, so the fix widened the rule rather than moving it' );
}

done_testing();

__END__

=head1 NAME

573-a-command-whose-output-is-not-ascii.t - a command job's non-ASCII output is stored as characters

=head1 DESCRIPTION

TKT-953, from the owner's report - his caption was the Chinese for "garbled
characters", over a screenshot of a job's output panel. Two functions read a child
process's output and they disagreed: C<feed_from_handle> decodes every line and
has since TKT-932, while C<run_due_job> read raw bytes and decoded nothing. Its
output reaches C<job_feed> through C<run_due_commands>, and the engine does not
round-trip byte strings - the JSON writer is in utf8 mode, so a byte held as a
character is encoded a second time and comes back as separate Latin-1
characters.

The decode belongs where the bytes are read, beside the one the feeder already
does, rather than in a compensating decode further down the chain.

=cut
