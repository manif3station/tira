#!/usr/bin/env perl
# Whether a monitor is running, on the page that lists it.
#
# TKT-861, his words: "No way to tell if the monitor is running." Filed the
# afternoon the five standing hunts moved onto board-owned jobs, which is when
# this section stopped being a list of curiosities and became where he watches
# the things that keep the board honest.
#
# THE GAP. The Repeated Jobs section shows a monitor's id, schedule, command and
# enabled flag, and says nothing about whether the process is up - so a monitor
# that died an hour ago looks exactly like one polling happily. That is the gap
# EPC-014 was filed for, one layer up: monitor-dead announces a stopped monitor
# on the police bridge, and the board he actually looks at stays silent.
#
# NOTHING NEW IS DECIDED HERE. Tira::Job::job_monitor_alive already decides
# liveness and Tira::CLI::Police::_running_processes already reads the process
# table; GET /jobs is already polled every thirty seconds. What is missing is
# carrying the verdict into that payload. A second liveness implementation
# written for the browser is the fault TKT-860 had to unpick and the one that
# made the engine and the browser disagree about attachment content types on
# TKT-713 - and here it would be worse, because the page and the bridge would
# answer the same question differently in front of him.
#
# THE DEPENDENCY IS SATISFIED, checked rather than assumed. The card's own key
# detail says this must wait for TKT-860, because liveness was wrong for
# d2-wrapped commands and showing it would paint every row red. TKT-860 is
# committed (d52e238, 347179c) and its logic is in the tree - _stamp_seconds at
# lib/Tira/Job.pm:341, the start-time comparison at :412. The install has not
# happened, which changes what he sees on the running board today but not the
# code this is built against.
#
# WRITTEN RED. The payload carries no liveness field at all.
#
# WHAT IS DELIBERATELY NOT HERE: the browser, which he keeps; and the HEARTBEAT,
# which is TKT-863 and a different feature - a heartbeat needs every monitor to
# report progress, and monitor-dead's own documentation says the monitors this
# epic absorbs are existing commands that will never cooperate. Liveness needs
# nothing from them.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

require Tira::Job;
require Tira::CLI::Browser;

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

# THE REAL CLOCK, deliberately, and this file is the exception rather than the
# rule. Every other suite here injects a fixed clock so an assertion is about
# behaviour instead of about when the tests happened to run.
#
# It cannot be done here. Since TKT-860 liveness is decided by comparing the
# start time the BOARD recorded against the start time the PROCESS TABLE
# reports, and only one of those two can be faked. With an injected clock the
# board records a fictional moment, the kernel reports the real one, they are
# hours apart, and a monitor that is demonstrably running is reported dead - by
# correct code, on a test that lied to it.
#
# Found exactly that way: the assertion failed, and a probe in a container
# showed job_monitor_alive answering ALIVE for the same shape of job.
my $tira = Tira->new;
$tira->project_new(
    name => 'Watched', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'WTS', epic_prefix => 'WTE', ticket_prefix => 'WTT',
);

my %provider = Tira::CLI::Browser::providers( tira => $tira, project => $root );
my $decode   = Tira::json_object();

ok( ref $provider{jobs} eq 'CODE', 'the page has a provider it reads jobs through' );

# --- three jobs, one of each kind that matters -------------------------------

my $cron = $tira->job_add(
    project => $root, schedule => '0 5 * * *', command => 'd2 tira.police' );
my $live = $tira->job_add(
    project => $root, schedule => 'monitor', command => "$^X -e 'sleep 45'" );
my $off = $tira->job_add(
    project => $root, schedule => 'monitor', command => "$^X -e 'sleep 45'" );
$tira->job_update( project => $root, id => $off->{id}, enabled => 0 );

require Tira::CLI::Job;
Tira::CLI::Job::run_now( $tira, { project => $root, id => $live->{id} } );

my ($started) = grep { $_->{id} eq $live->{id} } @{ $tira->job_list( project => $root ) };
ok( $started->{pid}, 'the monitor under test really was started' );

# --- what the page is told ---------------------------------------------------

my $answer = $provider{jobs}->();

# non-empty is the whole claim: every field assertion below would fail
# confusingly against an empty body, and the decode would throw first.
like( $answer, qr/\S/, 'the jobs provider answers with something' );

my $rows = $decode->decode($answer);
is( ref $rows, 'ARRAY', 'and it is the list of jobs the page renders' );
is( scalar @{$rows}, 3, 'all three jobs are in it' );

my %row = map { $_->{id} => $_ } @{$rows};

# THE ASSERTION THIS CARD IS ABOUT.
ok( exists $row{ $live->{id} }{running},
    'a monitor row carries whether its process is running' );
ok( $row{ $live->{id} }{running},
    'and says so truthfully for one that is up' );

# --- the two silences, which must stay silent --------------------------------
#
# monitor-dead already takes this stance and it is worth matching rather than
# inventing: a cron job is not supposed to be up between runs, and a disabled
# monitor is absent on purpose. An indicator reading "not running" on every cron
# row teaches him to ignore it, which is the failure this card exists to end.

ok( !exists $row{ $cron->{id} }{running},
    'a cron job carries no liveness at all, rather than a negative one' );
ok( !exists $row{ $off->{id} }{running},
    'and neither does a disabled monitor, which is absent on purpose' );

# --- the same board, after the process dies ----------------------------------
#
# The half that makes the indicator worth having. A field that only ever says
# "up" is a decoration.

kill 'TERM', $started->{pid};
waitpid $started->{pid}, 0;

my $after = $decode->decode( $provider{jobs}->() );
my %later = map { $_->{id} => $_ } @{$after};
ok( exists $later{ $live->{id} }{running},
    'the field is still there once the process has gone' );
ok( !$later{ $live->{id} }{running},
    'and now says it is not running - same board, same request, two answers' );

# --- and it agrees with the rule that reports it on the bridge ---------------
#
# Two answers to one question, one on the page and one on the police bridge, is
# the fault this card must not create. Asked of the engine directly rather than
# through a second path.

{
    my $processes = Tira::CLI::Job::_running_processes_for_jobs();
    my ($record) = grep { $_->{id} eq $live->{id} } @{ $tira->job_list( project => $root ) };
    is( Tira::Job::job_monitor_alive( $record, $processes ) ? 1 : 0,
        $later{ $live->{id} }{running} ? 1 : 0,
        'the page and job_monitor_alive give the same verdict for the same job' );
}

# --- read the process table once, not once per monitor -----------------------
#
# _running_processes is the expensive call. A six-monitor board polling every
# thirty seconds would read it six times a poll for no gain, and the provider
# has every job in hand before it needs the first verdict.

{
    my $reads = 0;
    no warnings 'redefine';
    local *Tira::CLI::Job::_running_processes_for_jobs = sub {
        $reads++;
        return [];
    };

    $provider{jobs}->();
    is( $reads, 1,
        'the process table is read once per request, whatever the monitor count' );
}

# --- a stored field does not smuggle liveness onto a row that must not have it
#
# Raised in review. The provider copies every stored field before deciding, so a
# record that already carried a running key - a hand-edited file, an import, a
# later engine change - would arrive at the page with one even on a cron row and
# render "Not running" against a job that is not supposed to be up. That is the
# false alarm this whole field is arranged to avoid, delivered by the one path
# that does not check.
#
# Same lesson as TKT-859's message-mode monitor: what the engine enforces on
# WRITE is not a guarantee at READ.

{
    my $path = File::Spec->catfile( $root, '.tira', 'jobs.json' );
    $path = ( grep { -f } (
        $path, File::Spec->catfile( $root, 'jobs.json' ) ) )[0];

    SKIP: {
        skip 'jobs file not where this test expected it', 2 if !$path;

        open my $in, '<:raw', $path or die $!;
        my $raw = do { local $/; <$in> };
        close $in;

        my $stored = $decode->decode($raw);
        $_->{running} = Cpanel::JSON::XS::true for @{$stored};

        open my $out, '>:raw', $path or die $!;
        print {$out} $decode->encode($stored);
        close $out;

        my %tainted = map { $_->{id} => $_ } @{ $decode->decode( $provider{jobs}->() ) };
        ok( !exists $tainted{ $cron->{id} }{running},
            'a stored running field is scrubbed from a cron row rather than passed through' );
        ok( !exists $tainted{ $off->{id} }{running},
            'and from a disabled monitor, which is absent on purpose' );
    }
}

# --- a cosmetic field must not take down the route it rides on ---------------
#
# Also from review. This route is polled every thirty seconds. One transient
# failure reading the process table would turn the whole jobs list into an error
# page, and the list is the part somebody actually needs - the indicator is the
# decoration on top of it.

{
    no warnings 'redefine';
    local *Tira::CLI::Job::_running_processes_for_jobs = sub { die "no process table here\n" };

    my $answer = eval { $provider{jobs}->() };
    my $why    = $@;

    # $@ read immediately and asserted on: ok(!eval{...}) would pass against any
    # failure at all, and what matters here is that there was none.
    is( $why, '', 'a process-table failure does not take the jobs route down' );

    my $rows = $decode->decode( $answer // '[]' );
    is( scalar @{$rows}, 3, 'and the job list is still served in full' );

    my %served = map { $_->{id} => $_ } @{$rows};
    ok( !exists $served{ $live->{id} }{running},
        'with liveness simply absent, which reads as not known rather than not running' );
}

# --- and the page renders it -------------------------------------------------
#
# The payload is half the card. These read the two view assets, the same way
# t/499 does, because the row and its styling are where he actually sees it.

{
    open my $fh, '<:raw', 'lib/Tira/views/jobs-editor.js' or die $!;
    my $js = do { local $/; <$fh> };
    close $fh;

    # non-empty is the whole claim: the assertions below are about what this
    # asset contains, and an unreadable file would fail them for the wrong
    # reason.
    like( $js, qr/\S/, 'the jobs view asset is readable' );

    like( $js, qr/jobs-card__up/, 'the row renders a liveness element' );

    # PRESENCE, not truth. A cron job and a disabled monitor carry no field at
    # all, and testing truthiness would render "Not running" against both -
    # which is the false alarm on every cron row that this card exists to
    # avoid, and the reason monitor-dead stays silent about them too.
    like( $js, qr/hasOwnProperty[^\n]*running/,
        'and decides by whether the field is PRESENT, not whether it is true' );

    open my $css_fh, '<:raw', 'lib/Tira/views/dashboard.css' or die $!;
    my $css = do { local $/; <$css_fh> };
    close $css_fh;

    like( $css, qr/\.jobs-card__up\b/, 'the stylesheet has a rule for it' );
    like( $css, qr/\.jobs-card__up\[data-running="1"\]/,
        'a running monitor is distinguishable without reading the text' );
    like( $css, qr/\.jobs-card__up\[data-running="0"\]/,
        'and so is one that is not' );

    # Colour alone is not a signal everybody can read. The row says which it is
    # in words as well, which the textContent above provides.
    like( $js, qr/"Not running"/,
        'the state is in words too, not only in a colour' );
}

done_testing();

__END__

=head1 NAME

500-a-monitor-that-says-whether-it-is-up.t - liveness in the Repeated Jobs payload

=head1 WHY

TKT-861. The section lists a monitor and says nothing about whether it is
running, so one that died an hour ago looks like one polling happily.

=head1 ONE DECISION, NOT TWO

The verdict comes from C<Tira::Job::job_monitor_alive> - the same call
C<monitor-dead> makes - so the page and the police bridge cannot answer the same
question differently. A liveness check written for the browser is the fault
TKT-860 had to unpick.

=head1 THE SILENCES ARE DELIBERATE

A cron job and a disabled monitor carry no liveness field at all. Both are
absent on purpose, and an indicator saying "not running" on every cron row is a
false alarm by design - the same stance C<monitor-dead> already takes.

=head1 NOT COVERED

The browser, which he keeps. And the heartbeat: TKT-863 asks each monitor to
report progress, which needs the monitors to cooperate. This needs nothing from
them.

=cut
