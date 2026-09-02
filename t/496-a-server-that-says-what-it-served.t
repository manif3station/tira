#!/usr/bin/env perl
# What the dashboard served, readable in the page that served it.
#
# TKT-852, from his own words: "run tira.dashboard -o browser with
# --show-logs", and his answer to Q-104 when asked what that should mean:
# "A logs panel inside the browser dashboard itself, so the log is read in the
# page rather than in the terminal."
#
# WHY HE ASKED. At 11:39 on 2026-09-02 the browser dashboard would not load for
# him on 192.168.1.189:7800, and there was no way to tell a request being
# refused from a request never arriving, because `tira.dashboard -o browser`
# starts a server and then says nothing at all about what it serves.
#
# WRITTEN RED, before the flag or the record exist.
#
# WHAT THIS DELIBERATELY DOES NOT COVER: the browser. He keeps those tests -
# "if you are running the browser test. leace it to me. skip the brwoser test".
# So this covers the contract underneath the panel, which is where the
# behaviour lives: the record, its bound, and the route.
#
# THE SCOPE TRAP, asserted rather than only written on the card. A panel in the
# page can only show requests that ARRIVED. A page that never loads produces no
# entries, so this cannot explain the unreachability that prompted it - he chose
# it over terminal streaming knowing that. Nothing here should grow into
# connection diagnostics.
#
# WHICH ASSERTIONS ARE ACTUALLY RED: every one that calls the recorder or the
# accessor, because neither exists. The "absent without the flag" assertion
# would pass against missing code too - a route that was never written is
# absent for the wrong reason - so the subject is established first and that
# assertion is placed after the ones that prove the thing can exist at all.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;
require Tira::DashboardWeb;
require Tira::CLI;

# --- the subjects -----------------------------------------------------------

ok( Tira::DashboardWeb->can('_record_request'),
    'the server can record a request it answered' );
ok( Tira::DashboardWeb->can('_request_log'),
    'and can hand back what it recorded, which is what the panel reads' );

# --- what it records is what he asked to see --------------------------------

Tira::DashboardWeb::_request_log_reset();
Tira::DashboardWeb::_record_request( '/data', 200 );
Tira::DashboardWeb::_record_request( '/jobs', 500 );

my $log = Tira::DashboardWeb::_request_log();
is( ref $log, 'ARRAY', 'the record reads back as a list' );
is( scalar @{$log}, 2, 'with one entry per request' );
is( $log->[-1]{path}, '/jobs', 'the newest entry is last, so the panel reads in order' );
is( $log->[-1]{status}, 500, 'and carries the status, which is the half that says what happened' );

# A REFUSED request is the case he was actually diagnosing: at 11:39 the
# question was whether requests were arriving and being turned away, or never
# arriving at all. An entry that only proved arrival would answer half of it.
ok( ( grep { $_->{status} == 500 } @{$log} ),
    'a request that did NOT succeed is recorded too, not just the happy ones' );

# --- bounded, because a dashboard is left open all day ----------------------
#
# CHK-001, decided and recorded before this file was written: a fixed ring of
# 200. A time window bounds nothing without assuming a request rate, and a
# diagnostics panel is looked at precisely when the rate is unusual.

Tira::DashboardWeb::_request_log_reset();
Tira::DashboardWeb::_record_request( "/req/$_", 200 ) for 1 .. 250;
my $bounded = Tira::DashboardWeb::_request_log();
is( scalar @{$bounded}, 200, 'the record stops at 200 entries rather than growing' );
is( $bounded->[-1]{path}, '/req/250', 'the newest request is kept' );
is( $bounded->[0]{path}, '/req/51', 'and the oldest are dropped, not the newest' );

# --- the panel does not record itself ---------------------------------------
#
# Raised in review, and it was a design fault rather than a wording one. The
# panel reads /logs every five seconds - twelve requests a minute - which is
# more than the four polled board routes produce between them. Recording those
# would fill the 200-entry ring with the act of LOOKING, and the requests
# somebody opened the panel to see would fall off the end within minutes.
#
# Asserted through the recorder rather than the hook, because the hook needs a
# live request; the exclusion it enforces is the same one.

Tira::DashboardWeb::_request_log_reset();
Tira::DashboardWeb::_record_request( '/data', 200 );
Tira::DashboardWeb::_record_request( '/jobs', 200 );
my $kept = Tira::DashboardWeb::_request_log();
is( scalar @{$kept}, 2, 'ordinary routes are recorded' );
ok( !( grep { $_->{path} eq '/logs' } @{$kept} ),
    'and nothing has put /logs in the record on its own' );

{
    open my $fh, '<:raw', 'lib/Tira/DashboardWeb.pm' or die "cannot read: $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    my ($hook) = $body =~ /hook after => sub \{(.*?)\n\};/s;
    ok( defined $hook, 'the after hook is where a request gets recorded' );
    like( $hook, qr{request->path eq '/logs'},
        'and it skips /logs, so the panel does not crowd out what it is showing' );
}

# --- the flag, and the route that does not exist without it -----------------

ok( Tira::CLI->can('run'), 'the CLI is there to be asked about its options' );
my $spec = do {
    open my $fh, '<:raw', 'lib/Tira/CLI.pm' or die "cannot read CLI.pm: $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    $body;
};
like( $spec, qr/'show-logs'/,
    'the CLI declares a --show-logs option at all' );

# Established the other way round so "absent" cannot pass vacuously: the
# provider name has to be a thing the app knows about before its absence means
# anything.
ok( Tira::DashboardWeb->can('build_psgi_app'),
    'the app builder is the thing that would carry a logs route' );

# --- the flag actually turns it on, through the real CLI --------------------
#
# Not "the option is declared" - that is a string in a file and would pass with
# nothing behind it. This runs the command with an injected browser_server, the
# same shape t/99 uses for --no-session-expire, and asserts the flag SET the
# thing it is supposed to set. A flag nothing reads is the exact fault the
# option guard two modules away exists to prevent, and the coverage gate caught
# this branch never running at all.

{
    use File::Temp ();
    use File::Spec;
    my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'logsboard' );
    my $tira = Tira->new( clock => sub {'2026-09-02T18:00:00Z'} );
    $tira->project_new(
        name => 'Logs', dir => $root, members => ['michael'],
        columns    => ['backlog, done'],
        sow_prefix => 'LGS', epic_prefix => 'LGE', ticket_prefix => 'LGT',
    );

    local $Tira::DashboardWeb::SHOW_LOGS = 0;
    my @calls;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
            command => 'dashboard.ticket', tira => $tira,
            argv => [ '-o', 'browser', '--show-logs' ],
            browser_server => sub { push @calls, {@_}; return 1 },
        ) };
    }
    ok( scalar @calls, '--show-logs is accepted by the browser dashboard' );
    ok( $Tira::DashboardWeb::SHOW_LOGS,
        'and it TURNS THE RECORD ON, rather than being a flag nothing reads' );
    like( $err . $out, qr/recent requests|shows them in the page/i,
        'and the board says what it is now keeping, where somebody starting it can see' );
    like( $err . $out, qr/nothing is written to disk|go no further/i,
        'including that nothing is written to disk, which is the part worth promising' );
}

# --- the panel is there only when the flag is ------------------------------
#
# Rendered rather than always-present-and-empty, for the same reason /logs
# answers 404 instead of an empty list: a panel showing nothing would say the
# board had answered nothing, which is a different claim from not keeping a
# record. Asserted in both directions, and the ON case first so the OFF case
# is not passing because the markup was never written.

{
    use File::Temp ();
    use File::Spec;
    my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'pageboard' );
    my $tira = Tira->new( clock => sub {'2026-09-02T18:00:00Z'} );
    $tira->project_new(
        name => 'Page', dir => $root, members => ['michael'],
        columns    => ['backlog, done'],
        sow_prefix => 'PGS', epic_prefix => 'PGE', ticket_prefix => 'PGT',
    );

    my $render = sub {
        return $tira->format_output(
            $tira->dashboard( project => $root, live => 1 ),
            output => 'table', live => 1,
        );
    };

    my $with = do { local $Tira::DashboardWeb::SHOW_LOGS = 1; $render->() };

    # non-empty is the whole claim: a precondition for the section assertions
    # below, which would pass happily against a page that rendered nothing.
    like( $with, qr/\S/, 'the board page has something in it at all' );
    like( $with, qr/board--logs/, 'with the flag the page carries a Requests section' );
    like( $with, qr/logs-lines/,
        'with a list for its lines, filled from /logs the way the jobs section is' );

    my $without = do { local $Tira::DashboardWeb::SHOW_LOGS = 0; $render->() };

    # non-empty is the whole claim, and here it carries real weight: the
    # unlike() below is the assertion that matters, and it would pass against a
    # page that failed to render at all. This is what stops "the section is
    # absent" being satisfied by "everything is absent".
    like( $without, qr/\S/, 'and the page without the flag still renders' );
    unlike( $without, qr/board--logs/,
        'but the section is absent rather than present and empty' );
}

# --- and it is refused where it would do nothing ----------------------------
#
# The card's own first test step asks for this, and without it --show-logs is
# accepted by every other output format and silently does nothing. That is the
# accepted-and-ignored fault this codebase refuses elsewhere: a flag that parses
# reads as confirmation. Found by walking the test steps at the verify gate
# rather than by a failing test, which is why it is worth having the step.

{
    my $tmp2  = File::Temp::tempdir( CLEANUP => 1 );
    my $root2 = File::Spec->catdir( $tmp2, 'refuseboard' );
    my $tira  = Tira->new( clock => sub {'2026-09-02T20:00:00Z'} );
    $tira->project_new(
        name => 'Refuse', dir => $root2, members => ['michael'],
        columns    => ['backlog, done'],
        sow_prefix => 'RFS', epic_prefix => 'RFE', ticket_prefix => 'RFT',
    );

    my $refused = !eval {
        local $ENV{TIRA_HOME} = $root2;
        Tira::CLI->run(
            command => 'dashboard.ticket', tira => $tira,
            argv => [ '-o', 'json', '--show-logs' ],
        );
        1;
    };

    # $@ read before anything else runs, because ok() can clobber it - and
    # asserted on directly, which is what t/149 looks for: a refusal that never
    # says WHICH refusal it got will pass against any failure at all, including
    # a typo in the command name.
    like( $@, qr/needs -o browser/,
        'the refusal says what it needs, not just that something went wrong' );
    ok( $refused, 'and --show-logs without -o browser is refused rather than ignored' );
}

done_testing();

__END__

=head1 NAME

496-a-server-that-says-what-it-served.t - the dashboard's own request log

=head1 WHY

TKT-852. He asked for C<tira.dashboard -o browser --show-logs> after the
dashboard would not load for him and nothing could say whether requests were
arriving. Asked what C<--show-logs> should mean, he chose "a logs panel inside
the browser dashboard itself, so the log is read in the page rather than in the
terminal" over streaming to the terminal or writing a file.

=head1 THE BOUND IS A DECISION, NOT A NUMBER

A fixed ring of 200 entries, recorded as CHK-001 before implementing. A time
window bounds memory only if a request rate is assumed, and the panel is read
precisely when the rate is unusual. The page already polls four routes every
thirty seconds, so 200 is roughly twenty-five minutes of idle history.

=head1 WHAT IT CANNOT DO

Only requests that ARRIVED are recorded. A page that never loads leaves no
entries, so this cannot diagnose the unreachability that prompted it. That is
his choice rather than an oversight, and the card's scope_out says so.

=cut
