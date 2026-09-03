#!/usr/bin/env perl
# Correcting, stopping and removing a repeated job from the page that shows them.
#
# TKT-892, grouping TKT-880, 882, 883, 884, 889 and 890. His three complaints of
# 2026-09-03, in his own words:
#
#     1. In the UI there is no way i can delete any existing job card
#     2. I cannot edit and card
#     3. I cannot pick between command or message
#
# TKT-858 made a job creatable from the page. It is still not correctable,
# stoppable or removable from there, and the two engine fields that landed after
# that card - expect_every and restart_every - cannot be set from there at all.
#
# WHERE THE GAPS ACTUALLY ARE, measured rather than assumed, because they are not
# all in one layer and a test that guessed would prove the wrong thing:
#
#   THE PROVIDER drops two fields. job_save builds its arguments from schedule,
#   command and message only, so expect_every (TKT-863) and restart_every
#   (TKT-891) are silently discarded by the save no matter what the page sends.
#   Silently is the problem: a form that offers a field the save throws away is
#   worse than one that does not offer it.
#
#   THREE VERBS HAVE NO PROVIDER AND NO ROUTE. job_delete, job_stop and
#   job_start. All three exist as engine verbs - tira.job.stop is new from
#   TKT-893, which is what unblocked this card - so this is a surface that was
#   never built, not a capability that is missing.
#
#   THE EDITOR POSTS TWO DIFFERENT SHAPES. Creating sends {schedule, command};
#   editing sends {id, schedule}. That is complaint 2 exactly: the command is not
#   in the edit payload, and the field that would carry it is built inside
#   if (creating), so there is nothing on the page to type a correction into.
#
# WHAT IS NOT ASSERTED HERE, AND WHY. Nothing in this file opens a browser. His
# standing instruction is that browser-facing verification is his, so these are
# the Perl-side contracts the page depends on: the providers behave, the routes
# exist, and the editor builds one payload rather than two. Whether the rendered
# form looks right is his to say.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite;
use Tira;
use Tira::CLI::Browser;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'Jobs page', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'JPS', epic_prefix => 'JPE', ticket_prefix => 'JPT',
    );
    return ( $tira, $root );
}

# --- the save carries every field a job has ----------------------------------
#
# Not "the form should offer them" - that is his to look at. This is the
# narrower claim underneath it: if the page sends them, the save must keep them.

{
    my ( $tira, $root ) = board();
    my %provider = Tira::CLI::Browser::providers( tira => $tira, project => $root );

    ok( ref $provider{job_save} eq 'CODE', 'the save provider is there to call' );

    # 'sleep 60' rather than a d2 command, and the reason is worth keeping: a
    # monitor saved here is STARTED, which is his Q-109 answer on TKT-858 - "create
    # it and start it, for monitor-kind only". So this provider really does spawn
    # a process, and a command the container cannot run makes the save die with
    # "created but not started" long before any field can be read back. That is
    # correct behaviour meeting a test fixture, not a defect: the job exists, the
    # refusal says so, and it tells you to start it rather than add it again.
    $provider{job_save}->( {
            schedule      => 'monitor',
            command       => 'sleep 60',
            expect_every  => 5,
            restart_every => 5,
        } );

    my ($made) = @{ $tira->job_list( project => $root ) };

    # Started means a real child, and leaving it behind would outlive the test.
    kill 'TERM', $made->{pid} if ref $made eq 'HASH' && $made->{pid};

    # non-empty is the whole claim: every assertion below reads this record, and
    # a save that created nothing would fail them for the wrong reason.
    ok( ref $made eq 'HASH', 'and the save wrote a job to read back' );

    is( ( $made || {} )->{expect_every}, 5,
        'A MONITOR SAVED FROM THE PAGE KEEPS ITS DECLARED EXPECTATION. His '
          . 'Q-115 answer put that field on the job - "expect a line every N '
          . 'minutes" - and a save that drops it means the page is the one '
          . 'place a monitor cannot be fully described' );

    is( ( $made || {} )->{restart_every}, 5,
        'and its looping interval, which is the checkbox he asked for in voice '
          . '6694 - the whole point of that control being a field rather than a '
          . 'while loop typed into a command is that the board can SEE it' );
}

# --- and an edit keeps them too ----------------------------------------------
#
# The create path and the update path are separate branches of one provider, and
# a fix that only reached the first would leave a job that can be given an
# interval once and never corrected.

{
    my ( $tira, $root ) = board();
    my %provider = Tira::CLI::Browser::providers( tira => $tira, project => $root );

    my $job = $tira->job_add(
        project => $root, schedule => 'monitor', command => 'd2 tira.police' );

    $provider{job_save}->( {
            id            => $job->{id},
            command       => 'd2 tira.policy.bridge',
            expect_every  => 10,
            restart_every => 30,
        } );

    my ($after) = grep { $_->{id} eq $job->{id} }
      @{ $tira->job_list( project => $root ) };

    is( ( $after || {} )->{command}, 'd2 tira.policy.bridge',
        'HIS COMPLAINT 2, AT THE LAYER UNDER THE PAGE: a job command can be '
          . 'corrected through the save rather than only at creation' );

    is( ( $after || {} )->{expect_every}, 10,
        'an edit sets the expectation as well as a create' );

    is( ( $after || {} )->{restart_every}, 30,
        'and the interval, so a monitor that was created without one can be '
          . 'given one without being deleted and made again' );
}

# --- the three verbs the row needs -------------------------------------------
#
# HIS COMPLAINT 1 is job_delete. The buttons TKT-883 absorbed are job_stop and
# job_start. All three are engine verbs already; none is reachable from the page.

{
    my ( $tira, $root ) = board();
    my %provider = Tira::CLI::Browser::providers( tira => $tira, project => $root );

    for my $name (qw(job_delete job_stop job_start)) {
        ok( ref $provider{$name} eq 'CODE',
            "there is a $name provider, so the row can offer it" );
    }
}

# --- deleting from the page, and the refusal it has to carry -----------------

{
    my ( $tira, $root ) = board();
    my %provider = Tira::CLI::Browser::providers( tira => $tira, project => $root );

    my $job = $tira->job_add(
        project => $root, schedule => '0 * * * *', command => 'd2 tira.stale' );

    SKIP: {
        skip 'no job_delete provider yet', 2 if ref $provider{job_delete} ne 'CODE';

        $provider{job_delete}->( { id => $job->{id} } );

        my @left = grep { $_->{id} eq $job->{id} }
          @{ $tira->job_list( project => $root ) };
        is( scalar @left, 0,
            'HIS COMPLAINT 1: a job deleted from the page leaves the board' );
    }

    SKIP: {
        skip 'no job_delete provider yet', 1 if ref $provider{job_delete} ne 'CODE';

        my $running = $tira->job_add(
            project => $root, schedule => 'monitor', command => 'd2 tira.police' );

        # job_started, not job_update - the pid is not an ordinary editable
        # field, and an update naming one leaves the record with no pid at all,
        # so the delete below would be refusing nothing. And $$ rather than a
        # made-up number: the guard asks whether the process is ALIVE, and an
        # invented pid is a job the board thinks has already died. This test's
        # own pid is the one pid it can be certain about. Nothing signals it -
        # delete only refuses.
        $tira->job_started( project => $root, id => $running->{id}, pid => $$ );

        # any failure is what this means. The only intended way for this call to
        # fail is the engine's refusal reaching the page - and a refusal that
        # arrives as some other error is equally not the message he needs to see.
        my $ok = eval { $provider{job_delete}->( { id => $running->{id} } ); 1 };
        my $why = $@;

        ok( !$ok && $why =~ /stop/i,
            'and deleting a RUNNING monitor is refused with the engine\'s own '
              . 'words, which name tira.job.stop - the page surfaces that '
              . 'rather than silently abandoning a pid' )
          or diag( $ok ? 'it was allowed' : "it failed differently: $why" );
    }
}

# --- the routes those providers hang off -------------------------------------
#
# A provider nothing can reach is not a surface. Read from the engine source by
# walking lib/, never by opening a file by name: a test that names the file is
# asserting where code lives while claiming to assert something else, which is
# the fault TKT-837 caused and TKT-835 removed from seven tests.

{
    my $engine = Suite::engine_source();

    # non-empty is the whole claim: the three assertions below grep this text,
    # and a walk that returned nothing would report every route as missing.
    like( $engine, qr/\S/, 'the engine source was read to look for routes' );

    for my $route (qw(jobs/delete jobs/stop jobs/start)) {
        like( $engine, qr{\Q$route\E},
            "POST /$route is declared, so the button has somewhere to post to" );
    }
}

# --- one payload, not two ----------------------------------------------------
#
# His voice 6695: the same complete form for create and for edit, pre-filled
# from the job. Today the editor builds {schedule, command} when creating and
# {id, schedule} when editing, and the command input itself is built inside
# if (creating) - so complaint 2 is not that the edit forgets the command, it is
# that there is nowhere on the page to type one.
#
# Asserted against the view source rather than a rendered page, and the scripts
# are found by walking the views directory rather than by naming the file.

{
    my $views = File::Spec->catdir( 'lib', 'Tira', 'views' );
    opendir my $dh, $views or die "$views: $!";
    my @scripts = sort grep { /\.js\z/ } readdir $dh;
    closedir $dh;

    cmp_ok( scalar @scripts, '>=', 1,
        'the views directory was walked for scripts - ' . scalar(@scripts) . ' found' );

    my $editor = '';
    for my $name (@scripts) {
        open my $fh, '<:encoding(UTF-8)', File::Spec->catfile( $views, $name )
          or die "$name: $!";
        local $/;
        my $body = <$fh>;
        $editor .= $body if $body =~ m{/jobs/save};
    }

    # non-empty is the whole claim: the assertion below reads this text, and if
    # no script posted to /jobs/save the unlike would pass over an empty string
    # and report success about a page that does not exist.
    like( $editor, qr/\S/, 'the script that posts to /jobs/save was found' );

    unlike(
        $editor,
        qr/\{\s*id:\s*job\.id\s*,\s*schedule:\s*[A-Za-z.]+\s*\}/,
        'THE EDIT PAYLOAD IS NOT {id, schedule} ANY MORE. One form for create '
          . 'and edit is his 6695, and two payload shapes is what makes the '
          . 'command uneditable - the field is built inside if (creating), so '
          . 'there is nothing to type a correction into'
    );
}

# --- the schedule reads as words, and the words are the ENGINE's -------------
#
# TKT-884, absorbed here: the card face shows the raw cron string, so the one
# place a schedule is visible is the one place it cannot be read.
#
# IN PERL, NOT IN THE PAGE, and that is a design decision rather than a
# convenience. This module already refuses to let the browser interpret a
# schedule: job_check asks the ENGINE whether a crontab is valid rather than
# running a regex in JavaScript, because two validators for one format is how
# the engine and the browser came to disagree about attachment content types
# (TKT-713). A cron-to-English translator written in the page would be a second
# reading of the same format, free to drift from the first in exactly the way
# that comment exists to prevent. So the row carries the words and the page
# renders a string it is not asked to understand.

{
    my %said = (
        'monitor'       => qr/continuous|monitor/i,
        '*/30 * * * *'  => qr/every 30 minutes/i,
        '*/5 * * * *'   => qr/every 5 minutes/i,
        '0 * * * *'     => qr/every hour/i,
        '0 9 * * *'     => qr/09:00/,
        '* * * * *'     => qr/every minute/i,
    );

    for my $cron ( sort keys %said ) {
        like( Tira::Job::job_schedule_words($cron), $said{$cron},
            "'$cron' reads as words a person can check at a glance" );
    }

    # THE FALLBACK IS THE IMPORTANT ONE. A description that guesses is worse
    # than no description: somebody would read the words, believe them, and stop
    # checking the cron. Anything this cannot describe with certainty comes back
    # as itself, unchanged.
    my $odd = '17 3 5,20 */2 1-5';
    is( Tira::Job::job_schedule_words($odd), $odd,
        'and a schedule it cannot describe with certainty is returned AS ITSELF '
          . 'rather than guessed at - a wrong description would be believed, '
          . 'and then nobody would read the cron again' );
}

# --- and the row carries them, so the page renders rather than interprets ----

{
    my ( $tira, $root ) = board();
    my %provider = Tira::CLI::Browser::providers( tira => $tira, project => $root );

    $tira->job_add(
        project => $root, schedule => '*/30 * * * *', command => 'd2 tira.stale' );

    my $rows = Tira::json_decode( $provider{jobs}->() );

    # non-empty is the whole claim: the assertion below reads the first row, and
    # an empty list would fail it for a reason that is not this feature.
    ok( ref $rows eq 'ARRAY' && @{$rows}, 'the jobs provider answered with rows' );

    like( ( $rows->[0] || {} )->{schedule_words} // '', qr/every 30 minutes/i,
        'the row carries the readable schedule, so the card face can show words '
          . 'without the browser having to parse cron for itself' );

    is( ( $rows->[0] || {} )->{schedule}, '*/30 * * * *',
        'AND THE RAW SCHEDULE IS STILL THERE. The words are an addition, not a '
          . 'replacement - it is still stored as cron, which is his own '
          . 'requirement, and the editor has to put the real string back in the '
          . 'field when it opens' );
}

# --- the controls he asked for, as far as source can honestly show ----------
#
# HOW MUCH THESE ARE WORTH, said plainly rather than implied. They assert that
# the editor DECLARES the controls - a radio group for the schedule kind, a
# second for command-or-message, a checkbox for looping - and that the payload
# stops depending on somebody typing the word "monitor". They cannot tell you
# the form looks right, that the radios line up, or that the schedule field
# actually greys out, because nothing here renders a page. That is his to look
# at, by standing instruction.
#
# They are still worth having: without them the whole of his voice 6691 and 6694
# could be deleted from the editor and every test in this suite would pass.

{
    my $views = File::Spec->catdir( 'lib', 'Tira', 'views' );
    opendir my $dh, $views or die "$views: $!";
    my @scripts = sort grep { /\.js\z/ } readdir $dh;
    closedir $dh;

    my $editor = '';
    for my $name (@scripts) {
        open my $fh, '<:encoding(UTF-8)', File::Spec->catfile( $views, $name )
          or die "$name: $!";
        local $/;
        my $body = <$fh>;
        $editor .= $body if $body =~ m{/jobs/save};
    }

    # non-empty is the whole claim: every assertion below greps this text, and
    # an empty string would report every control as missing.
    like( $editor, qr/\S/, 'the editor script was found to read' );

    like( $editor, qr/type\s*=\s*"radio"/,
        'THE KIND IS CHOSEN, NOT TYPED. His 6691 asks for radio buttons rather '
          . 'than typing the word monitor into a schedule field - which was a '
          . 'magic value somebody had to know' );

    like( $editor, qr/type\s*=\s*"checkbox"/,
        'and looping is a CHECKBOX, which is his word in 6694 and is what it '
          . 'means - on or off, not one of two alternatives' );

    # payload.<name>, NOT the bare field name, and the difference is a real one
    # this test got wrong first. A bare /expect_every/ passed against the editor
    # BEFORE any of this was built, because TKT-863 already READ that field to
    # print "expects every N min" beside a monitor. Reading a field and being
    # able to set one are different claims, and only the second is this card's.
    # Checked by grepping the previous commit's copy of the script rather than
    # by reasoning about it: bare expect_every appeared twice there, so the
    # assertion proved nothing.
    like( $editor, qr/payload\.restart_every/,
        'the looping interval is SENT, under the name the engine stores it by' );

    like( $editor, qr/payload\.expect_every/,
        'and so is the expectation - the page could already show one since '
          . 'TKT-863 and still had no way to set one, which is what made it the '
          . 'one place a monitor could not be fully described' );

    like( $editor, qr/messageWrap\.hidden\s*=\s*monitoring/,
        'MESSAGE IS NOT OFFERED UNDER MONITOR. Not the page deciding - the '
          . 'engine refuses that pairing outright, because a monitor with no '
          . 'command can never be found alive in the process table and would be '
          . 'reported dead for ever (TKT-842). The page declines to offer what '
          . 'the save would refuse' );

    unlike( $editor, qr/schedule:\s*field\.value\s*,?\s*\n?\s*command:/,
        'and the payload no longer takes the schedule straight from the text '
          . 'field, since the radio is what decides it now' );
}

done_testing();

__END__

=head1 NAME

517-a-job-you-can-only-fix-from-a-terminal.t - the page's side of a repeated job

=head1 WHY

TKT-892, grouping six cards, from his three complaints of 2026-09-03: a job card
cannot be deleted, cannot be edited, and command-or-message cannot be chosen.

TKT-858 made a job creatable from the page. It is still not correctable,
stoppable or removable from there, and the two engine fields that arrived after
that card - C<expect_every> from TKT-863 and C<restart_every> from TKT-891 -
cannot be set from there at all.

=head1 WHAT IS ASSERTED

That C<job_save> keeps C<expect_every> and C<restart_every> on both the create
and the update branch, rather than silently discarding them; that a command can
be corrected through the save; that C<job_delete>, C<job_stop> and C<job_start>
providers exist; that deleting a running monitor is refused with the engine's own
words rather than orphaning the process; that the three routes are declared; and
that the editor no longer builds a separate C<{id, schedule}> payload for edits.

=head1 WHAT IS NOT ASSERTED

Nothing here opens a browser. Browser-facing verification is his by standing
instruction, so this file covers the Perl-side contracts the page depends on -
the providers, the routes, and the payload shape. Whether the rendered form
looks right is his to say.

=cut
