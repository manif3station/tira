#!/usr/bin/env perl
# A running monitor's output, on the one stream the agent reads.
#
# TKT-851, his instruction on 2026-09-02 at 16:55, verbatim: "Monitors should
# not have separate logs. They all go to the policy bridge."
#
# THE GAP. A monitor writes to .tira/jobs/<id>.log (TKT-842) and nowhere else,
# so a live poller can be saying something useful while the agent, which reads
# the bridge, never hears it. monitor-dead made a STOPPED monitor say so; this
# is a RUNNING one still being unheard.
#
# MEASURED CONSEQUENCE, from the card: it is why TKT-840 could not migrate the
# Telegram bridge onto a board-owned job. A monitor-kind job would have put his
# messages into a file nobody opens and silently cut the channel.
#
# THE CONSTRAINT THAT SHAPES ALL OF IT. TKT-842 chose a file deliberately: a
# pipe with no reader fills at about 64KB and blocks the child forever - a
# monitor that has stopped doing anything while still looking started, which is
# worse than the silence being fixed. So "goes to the bridge" cannot mean
# handing the child a pipe. The file stays; something follows it.
#
# WHICH IS WHY THE OFFSET, AND NOT THE LEDGER. job-due announces once per due
# WINDOW using the sub_key mechanism from TKT-698, and the card's own key detail
# says to read that first. Read, and departed from: a stream has no windows. The
# question is not "has this window been announced" but "which bytes have been
# said", and an offset answers it exactly. A ledger keyed on text would also
# break the moment a poller legitimately printed the same line twice, which one
# doing the same work every minute does constantly.
#
# WRITTEN RED. No rule follows a monitor's output today.
#
# WHAT IS STILL OPEN AND DELIBERATELY NOT ASSERTED HERE: what happens to the
# spool file after it is drained - truncated, deleted, or not written at all.
# That is Q-111, asked of him with a voice note because his instruction and the
# deadlock constraint pull against each other. Every assertion below holds
# whichever way he answers, which is why the card could proceed to a red test
# without the answer.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

require Tira::Job;

my $tmp   = File::Temp::tempdir( CLEANUP => 1 );
my $root  = File::Spec->catdir( $tmp, 'board' );
my $store = File::Spec->catfile( $tmp, 'ledger.json' );

my $tira = Tira->new( clock => sub {'2026-09-03T02:00:00Z'} );
$tira->project_new(
    name => 'Heard', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'HRS', epic_prefix => 'HRE', ticket_prefix => 'HRT',
);

# --- the rule has to exist before anything can be asked of it ----------------
#
# Established first so every assertion below fails for the right reason. Without
# this, "no findings" would be indistinguishable from "the rule is not declared
# and police silently watched nothing", which is the shape of absence that makes
# a red run look like a passing one.

my $rules = $tira->policy_rules;
ok( scalar @{$rules} > 0, 'the engine declares policy rules at all' );
ok( ( grep { $_ eq 'monitor-output' } @{$rules} ),
    'monitor-output is one of them - a rule that carries a monitor\'s output to the bridge' );

# --- a monitor, started, with something to say -------------------------------

my $monitor = $tira->job_add(
    project => $root, schedule => 'monitor',
    command => 'tira-monitor-under-test --poll',
);
is( $monitor->{schedule_kind}, 'monitor', 'a monitor-kind job to follow' );

my $cron = $tira->job_add(
    project => $root, schedule => '*/5 * * * *',
    command => 'tira-cron-under-test --once',
);
is( $cron->{schedule_kind}, 'cron', 'and a cron job beside it, to be left alone' );

my $pid = 424243;
eval { $tira->job_started( project => $root, id => $monitor->{id}, pid => $pid ); 1 }
  or diag( "job_started refused: " . ( $@ || 'no error' ) );

my $alive = {
    pid => $pid, started_at => '2026-09-03T02:00:00Z',
    command => 'tira-monitor-under-test --poll',
};

# THE MONITOR CALLS IN. Was say_into_log, appending to a per-job spool that
# police followed from an offset; TKT-851's second implementation replaced that
# with a feeder, after his Q-112 answer that each output be registered to
# whoever talked to the police. This calls what the feeder calls.
sub say_into_log {
    my (@lines) = @_;
    $tira->job_feed( project => $root, id => $monitor->{id}, lines => \@lines );
    return;
}

# NOT named pass(). The first version was, and it redefined Test::More's own
# pass() - "Prototype mismatch: sub main::pass (;$) vs none". A test file that
# quietly replaces one of the assertion functions it is using is a trap for
# whoever edits it next.
sub carried {
    my $policy = eval {
        $tira->policy_add(
            project => $root, rule => 'monitor-output', action => 'log-only' );
    };
    return [] if !$policy;
    my $result = $tira->police_pass(
        project => $root, store => $store, world => { processes => [$alive] } );

    # The pass does NOT drain - t/86 requires a pass to change not one byte of
    # the board, so the engine hands out what it announced and the CLI clears it
    # after the bridge. This stands in for that step, which is what makes the
    # "not announced twice" assertion below mean anything.
    require Tira::CLI::Police;
    Tira::CLI::Police::advance_monitor_output( $tira, { project => $root }, $result );

    $tira->policy_remove( project => $root, id => $policy->{id} );
    return $result->{violations} // [];
}

# --- what it says reaches the bridge -----------------------------------------

say_into_log( 'hunt found nothing this hour', 'next sweep at 03:00' );

my $first = carried();
cmp_ok( scalar @{$first}, '>', 0,
    'a running monitor with new output produces a finding' );
like( join( ' ', map { $_->{detail} // '' } @{$first} ), qr/hunt found nothing this hour/,
    'and the finding carries what the monitor actually said, not a generic notice' );

# --- and is not said again ---------------------------------------------------
#
# The assertion the card turns on. A rule that repeated every pass would make
# the bridge unreadable, which fails in the same direction as the silence it is
# fixing.

my $second = carried();
is( scalar @{$second}, 0,
    'the same output is not announced a second time' );

# --- taking it is what does it, not text matching ----------------------------
#
# A poller doing the same work every minute prints the same line constantly, so
# a ledger keyed on the text would swallow real repetitions. What has been
# carried is REMOVED from the record instead, which is why the same words can
# arrive again and still be news.

{
    my ($record) = grep { $_->{id} eq $monitor->{id} }
      @{ $tira->job_list( project => $root ) };
    is( scalar @{ $record->{output} || [] }, 0,
        'what was carried to the bridge is gone from the record' );
    ok( $record->{last_output_at},
        'but that it called in is still on the record - draining what a monitor '
          . 'said must not erase that it spoke' );
}

# --- a line the monitor really did repeat is announced again -----------------

say_into_log('hunt found nothing this hour');
my $again = carried();
cmp_ok( scalar @{$again}, '>', 0,
    'a line the monitor genuinely printed twice is announced twice - what was '
      . 'carried is taken, not remembered as text' );

# --- the timestamp TKT-863 will read -----------------------------------------
#
# From this card's KD7: a monitor whose output reaches the bridge has reported
# progress by that act. Recording WHEN turns TKT-863's heartbeat into a reading
# of one field rather than a second mechanism needing cooperation from monitors
# that will never give it.

{
    my ($record) = grep { $_->{id} eq $monitor->{id} }
      @{ $tira->job_list( project => $root ) };
    ok( $record->{last_output_at},
        'the job records when output last arrived from it' );
}

# --- silence stays silent ----------------------------------------------------

my $quiet = carried();
is( scalar @{$quiet}, 0,
    'a monitor with nothing new to say produces nothing' );

# --- and a cron job is never followed ----------------------------------------
#
# It has no long-running process and never calls in. Asserted rather than
# assumed, because the same mistake on the dashboard would have put an
# indicator on every cron row.

{
    my ($record) = grep { $_->{id} eq $cron->{id} }
      @{ $tira->job_list( project => $root ) };
    is( scalar @{ $record->{output} || [] }, 0,
        'a cron job is not followed at all - nothing is kept for it' );
    ok( !defined $record->{last_output_at},
        'and it has never called in, because it is not asked to' );
}

# --- a chatty monitor cannot flood the bridge --------------------------------
#
# And the cap SAYS what it dropped. A bridge that truncates silently is a bridge
# that lies, and this whole epic exists because silence and nothing-to-say
# looked identical.

{
    say_into_log( map { "line $_ of a very chatty poller" } 1 .. 500 );
    my $flood = carried();
    cmp_ok( scalar @{$flood}, '<', 500,
        'a monitor printing 500 lines does not put 500 findings on the bridge' );

    # THE NEWEST LINES, NOT THE FIRST. Raised in review: what somebody wants
    # from a poller that has said five hundred things is what it is saying NOW,
    # not how the flood began. The dropped count still says how much came
    # before it.
    my $said = join ' ', map { $_->{detail} // '' } @{$flood};
    like( $said, qr/line 500 of a very chatty poller/,
        'and the lines it does show are the NEWEST, which is what a monitor is for' );
    unlike( $said, qr/line 1 of a very chatty poller\b/,
        'rather than the opening of the burst' );
    like( join( ' ', map { $_->{detail} // '' } @{$flood} ), qr/\b\d+ (?:more|dropped|further)\b/,
        'and the bridge is told how many it did not show, rather than being '
          . 'quietly truncated' );
}

# --- and an age on it is refused ---------------------------------------------
#
# monitor-output declares forbids => ['age'], for the same reason monitor-dead
# does: output that has ARRIVED does not become more arrived by waiting, and a
# grace period here is the silence spelled as policy. t/79 requires every
# forbidden option to have a test that actually hands it over - a declaration
# nothing exercises is a refusal nobody has seen work.

{
    my $refused = !eval {
        $tira->policy_add( project => $root, rule => 'monitor-output',
            action => 'log-only', age => '1h' );
        1;
    };

    # $@ read immediately and matched, not merely counted: ok(!eval{...}) would
    # pass against a typo in the rule name, which is the failure this assertion
    # would then be hiding rather than catching.
    like( $@, qr/age/i,
        'an age on monitor-output is refused, and the refusal says which option' );
    ok( $refused, 'so the policy is not stored with a grace period on it' );
}

# --- a carriage return does not reach the bridge -----------------------------
#
# Also from review. A monitor writing Windows line endings would otherwise put a
# CR inside the message, where it corrupts the line rather than ending it.

{
    # Fed with the CR still on it, the way the feeder receives it from a
    # monitor reading a Windows-ended stream - stripping it here would test the
    # fixture rather than the code.
    $tira->job_feed( project => $root, id => $monitor->{id},
        lines => ["a line that ends the Windows way\r"] );

    my $crlf = carried();
    my $said = join ' ', map { $_->{detail} // '' } @{$crlf};

    # non-empty is the whole claim: the denial below is about what this message
    # does not contain, and an empty one would satisfy it while proving nothing.
    like( $said, qr/\S/, 'the CRLF line was carried' );
    like( $said, qr/a line that ends the Windows way/, 'with its text intact' );
    unlike( $said, qr/\r/, 'and no carriage return reached the bridge' );
}

done_testing();

__END__

=head1 NAME

502-a-monitor-talking-to-a-file-nobody-reads.t - a monitor's output on the bridge

=head1 WHY

TKT-851, his instruction: "Monitors should not have separate logs. They all go
to the policy bridge." A monitor writes to a per-job file and nowhere else, so a
live poller can be saying something useful while nobody hears it.

=head1 THE FILE STAYS

TKT-842 chose a file because a pipe with no reader fills at about 64KB and
blocks the child forever. "Goes to the bridge" therefore means something
B<follows> the file, not that the child is handed a pipe.

=head1 AN OFFSET, NOT THE LEDGER

C<job-due> announces once per due window with the C<sub_key> ledger. A stream
has no windows: the question is which bytes have been said, and an offset
answers it exactly. A ledger keyed on text would also swallow the repetitions a
poller legitimately prints - asserted here, because a monitor doing the same
work every minute says the same thing every minute.

=head1 NOT ASSERTED

What becomes of the spool after draining - Q-111, open with him. Every assertion
here holds whichever way he answers.

=cut
