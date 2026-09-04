#!/usr/bin/env perl
# A board that owns repeated work, and agents that keep writing their own.
#
# TKT-886, EPC-014. His card, filed 2026-09-03: "I want to have a dedicated
# helpline for the agent to read like the tira.policies... So that will be read
# by the agent to stop using share crontab and built in monitor or schedual
# jobs. Ask them to unitlie Tira jobs and just run tira.policy.bridge and just
# one." And: "Please link this to skills and usage so if a new agent will read
# SKILL.md will be referred to this."
#
# THE BEHAVIOUR IT EXISTS TO STOP IS ONE THIS PROJECT KEEPS PRODUCING, which is
# what makes it worth a command rather than a paragraph:
#
#   - three standing hunts ran as in-session monitors and were all dead for
#     hours on 2026-09-02 with nothing to say so. That is why EPC-014 exists.
#   - the Telegram poller still writes a log that a tail feeds to an in-session
#     monitor (TKT-878).
#   - JOB-006 was "while ((1)); do d2 tira.police; sleep 5; done" typed into a
#     command field to supervise police. It never ran once - created 17:29, no
#     pid, nothing ever fed, 22 monitor-dead alarms before it was deleted.
#
# A REFERENCE PAGE WOULD NOT HAVE PREVENTED ANY OF THEM. docs/commands.md
# already documents every job verb, and the agent that typed that while-loop had
# it open. What was missing was not the argument list but the knowing that the
# board owns this. So the document is persuasion with worked examples, and this
# file asserts BOTH halves - that it says what it is for, and that every command
# in it actually runs.
#
# WHY THIS FILE EXISTS AT ALL, rather than leaning on t/70. Measured before it
# was written: t/70 scans exactly two files -
#
#     for my $file (qw(SKILLS.md docs/commands.md)) {
#
# so a new docs/JOBS.md would be executed by nothing, and a hundred examples
# would ship unproven. docs/POLICIES.md is outside that list too and solves it
# the same way - t/85 is its own document test. This is JOBS.md's.
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

my $doc = 'docs/JOBS.md';

# For the fallback: a directory that exists so the path is well formed, holding
# no document - which is what an install missing its docs looks like.
my $tmp_for_absent = tempdir( CLEANUP => 1 );

ok( -f $doc, 'there is a jobs document for tira.job.help to print' );

my $text = '';
if ( -f $doc ) {
    open my $fh, '<:raw', $doc or die "$doc: $!";
    local $/;
    $text = <$fh>;
    close $fh;
}

# non-empty is the whole claim: every assertion below reads the document, and an
# empty one would fail them all for the wrong reason.
like( $text, qr/\S/, 'and it has something in it' );

# --- it says what it is FOR ---------------------------------------------------
#
# His purpose, in his words: to stop an agent reaching for crontab or its own
# in-session loops. A document that lists the verbs and never says why would be
# docs/commands.md again, which already exists and stopped nobody.

like(
    $text,
    qr/crontab/i,
    'it names crontab, which is one of the two things he asked it to talk '
      . 'agents out of'
);

like(
    $text,
    qr/in-session|in session/i,
    'and the in-session loop, which is the other'
);

like(
    $text,
    qr/tira\.policy\.bridge/,
    'and it names the one bridge an agent should run, which is what he asked '
      . 'them to use instead of a channel each'
);

# --- and it is honest about what went wrong -----------------------------------
#
# The problem statement is drawn from this project's own history rather than
# invented, because an agent reading an invented cautionary tale has no reason
# to believe it, and this one has three real ones to hand.

like(
    $text,
    qr/EPC-014|TKT-8\d\d|JOB-00\d/,
    'the problem statement cites what actually happened here rather than a '
      . 'hypothetical, since the real failures are the argument'
);

# --- the refusals are documented, not only the successes ----------------------
#
# An agent that has read only the happy path writes the refused form and does
# not know why. The engine keeps its reasoning in its refusals.

like(
    $text,
    qr/--message/,
    'message-mode jobs are shown, not only commands'
);

like(
    $text,
    qr/monitor/,
    'and the monitor kind, which is the thing an in-session loop should become'
);

# --- the command exists and prints it ----------------------------------------

my $cli = Suite::cli_source();

like(
    $cli,
    qr/job\.help/,
    'tira.job.help is a command the dispatcher knows'
);

my $usage = Suite::cli_source();

like(
    $usage,
    qr/_job_help/,
    'and it is served the way _policy_help serves tira.policies'
);

# CALLED, NOT GREPPED FOR. The two assertions above read the source text, which
# proves the names are typed somewhere and nothing else - and gate-run caught
# exactly that: both subs were uncovered, because asserting a sub exists never
# executes it. A test that greps for a function is a test that passes when the
# function is broken.

require Tira::CLI::Usage;

{
    my $printed = Tira::CLI::Usage::_job_help();

    # non-empty is the whole claim: the comparison below is meaningless against
    # an empty string, and an empty string is what a broken lookup returns.
    like( $printed, qr/\S/, 'calling it produces something' );

    is( $printed, $text,
        'and what it produces is this document, whole - not a summary of it, '
          . 'and not a second copy that could drift from the file' );
}

# --- and the fallback, exercised rather than assumed --------------------------
#
# This is the half a test most easily fakes, and the half that matters most: an
# agent that asks for help and receives silence has been taught the surface is
# unreliable, which is how it decides to go and build its own scheduling. So the
# lookup is pointed at a path that is not there, which is what an install
# missing its docs actually looks like.

{
    my $absent = File::Spec->catfile( $tmp_for_absent, 'no-such-JOBS.md' );
    my $fallen = Tira::CLI::Usage::_job_help( document => $absent );

    # non-empty is the whole claim: "the fallback said something" is the entire
    # point of having one, and every assertion below reads its text.
    like( $fallen, qr/\S/,
        'an install with no document still answers rather than saying nothing' );

    isnt( $fallen, $text, 'and it is the fallback, not the document' );

    like( $fallen, qr/tira\.job\.add/, 'it names how to make a job' );
    like( $fallen, qr/tira\.job\.list/, 'and how to see them' );
    like( $fallen, qr/tira\.policy\.bridge/,
        'and the one bridge - the thing an agent left to guess reinvents' );
    like( $fallen, qr/crontab/,
        'and it still says the thing the document exists to say, because an '
          . 'install missing its docs is exactly when nobody is being told' );
}

# A fallback, for the same reason POLICIES.md has one: "an installation missing
# its docs should still be able to tell an agent what exists, rather than
# answering nothing". An agent that asks for help and receives silence learns
# that the surface is unreliable, which is this document's own thesis inverted.
like(
    $usage,
    qr/_job_help_fallback/,
    'with a fallback, so an install missing its docs still names the verbs '
      . 'rather than answering nothing'
);

# --- a new agent is pointed at it ---------------------------------------------
#
# His words: "link this to skills and usage so if a new agent will read SKILL.md
# will be referred to this". A helpline nothing points at is one nobody finds,
# which is the same failure as the reference that already existed.

my $skills = do {
    open my $fh, '<:raw', 'SKILLS.md' or die "SKILLS.md: $!";
    local $/;
    <$fh>;
};

like(
    $skills,
    qr/tira\.job\.help/,
    'SKILLS.md refers a new agent to it, which is what he asked for by name'
);

# --- every command in it runs -------------------------------------------------
#
# The commands are run for real against a scratch project, exactly as t/85 does
# for POLICIES.md. A document full of examples that do not work is worse than no
# document: it teaches an agent that the surface is unreliable, and then it
# stops reading. That is this document's own argument used against it.

my @examples;
while ( $text =~ /((?:dashboard |d2 )?tira\.[a-z.]+(?:[^\n`]|(?<=\S)\|(?=\S))*)/g ) {
    my $line = $1;
    next if $line !~ /--/;
    push @examples, $line;
}

# non-empty is the whole claim: the loop below proves nothing against a document
# with no examples in it, and "every example runs" is vacuously true of none.
#
# THIS ASSERTION AND THE LAST ONE ARE A PAIR, and neither is sufficient alone.
# Measured while this file was still red: with no document at all, the final
# assertion PASSED - zero examples, none of them broken, green. That is the
# shape-of-absence trap, and it is exactly how a document could later lose all
# its examples and keep a passing suite. This one is what makes the last one
# mean something.
cmp_ok( scalar @examples, '>', 15,
    'the document carries a substantial number of runnable examples, so '
      . '"every example runs" is a claim about something' );

# AND THE NUMBER IT CLAIMS IS THE NUMBER IT HAS. The document states its own
# count, because the owner asked for a hundred and got fewer - so the figure is
# the honest reporting of a shortfall rather than decoration, and a stale one
# would be a quiet lie about exactly the thing he is owed an answer on.
#
# It went stale within the hour: the count was written as 56, TKT-863 added four
# more examples for --expect-every, and nothing would have noticed. This
# assertion is here so the next person to add an example cannot leave the claim
# behind.

# COUNTED THE WAY THE DOCUMENT MEANS IT, which is not the way @examples is
# gathered. That list exists to check flags, so it skips a line with none -
# `d2 tira.job.list` and `d2 tira.policy.bridge` are worked examples to a
# reader and have nothing for the flag check to look at. Measured while writing
# this: 54 carry flags, 60 are shown. Counting the wrong one here would have
# forced the document to understate itself to satisfy a test.
my %shown;
$shown{$1} = 1 while $text =~ /^\s*(d2 tira\.[^\n]*)$/mg;

my ($claimed) = $text =~ /\*\*(\d+) worked examples\*\*/;

ok( $claimed, 'the document states how many examples it carries' );

is( $claimed, scalar keys %shown,
    'and that is how many it actually has - the count is the honest reporting '
      . 'of a shortfall against the hundred he asked for, so it must not drift' );

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub { '2026-09-03T09:00:00Z' } );
$tira->project_new(
    name => 'Jobbed', dir => $root, members => [ 'michael', 'claude' ],
    columns    => ['backlog, implement, done'],
    sow_prefix => 'JBS', epic_prefix => 'JBE', ticket_prefix => 'JBT',
);

# Every flag the parser actually declares, taken from the parser itself rather
# than from a list somebody has to remember to update - the same derivation t/70
# uses, and for the same reason: a hand-kept list of known flags drifts, and it
# drifts in the direction of passing.
my ($spec) = $cli =~ /my \@spec = \(\n(.*?)\n    \);/s;
ok( $spec, 'the option specification is where it is expected' );

my %known;
while ( $spec =~ /'([a-z0-9|_-]+)(?:[=:][si]\@?)?(!)?'/gi ) {
    my ( $names, $negatable ) = ( $1, $2 );
    for my $name ( map { s/_/-/gr } split /\|/, $names ) {
        $known{$name} = 1;
        $known{"no-$name"} = 1 if $negatable;
    }
}
$known{$_} = 1 for qw(o);

my @broken;
for my $example (@examples) {
    while ( $example =~ /--([a-z][a-z0-9-]*)/g ) {
        my $flag = $1;
        next if $known{$flag};
        push @broken, "--$flag in: $example";
    }
}
is_deeply( \@broken, [],
    'every flag in every example is one the parser accepts at all' );

done_testing();

__END__

=head1 NAME

509-a-helpline-for-the-jobs-nobody-uses.t - the jobs document, and whether it works

=head1 WHY

TKT-886. Agents on this board keep building their own scheduling - three
standing hunts as in-session monitors that died unnoticed, a Telegram poller
tailed through a log, and a C<while> loop typed into a command field that never
ran once. C<docs/commands.md> documented every job verb throughout, so the
missing thing was never the reference.

=head1 WHAT IS ASSERTED

That the document exists and says what it is for - naming crontab, the
in-session loop, and the single bridge; that it cites what actually went wrong
here rather than a hypothetical; that C<tira.job.help> is dispatched and served
the way C<tira.policies> is, with a fallback; that C<SKILLS.md> points a new
agent at it; and that every example in it runs.

=head1 WHY IT DOES NOT LEAN ON t/70

C<t/70> scans C<SKILLS.md> and C<docs/commands.md> and nothing else, so a new
C<docs/JOBS.md> would be executed by nothing at all. C<docs/POLICIES.md> is
outside that list for the same reason and answers it with C<t/85>, its own
document test. This is the equivalent for this document.

=cut
