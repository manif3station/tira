#!/usr/bin/env perl
# A message job opened as an empty command job.
#
# TKT-914, EPC-014. His report, 2026-09-04: "If I edit a job that isn't command
# but is a message. I cannot see the saved message that I want to edit. Instead
# it should me a blank command text box and selected the command radio button
# instead of select the message radio. So I click on the message radio button,
# the message text input is also blank."
#
# I filed it as two faults. Reading the source, it is ONE OMISSION with two
# symptoms: the editor never asks what mode the job is.
#
#   222  const modeCommand = makeRadio(modeRow, modeName, "command", "Command", true);
#   223  const modeMessage = makeRadio(modeRow, modeName, "message", "Message", false);
#
# Hardcoded. Every job opens showing Command selected.
#
#   206  commandField.value = (job && job.command) || "";
#   386  payload.message = commandField.value;
#
# THERE IS ONLY ONE TEXT INPUT. It is filled from job.command whatever the job
# is, and read into payload.message when the mode is message. A message job has
# no command, so the box is empty - and a save from that screen writes the empty
# box over the stored message.
#
# WHY THIS IS PRIORITY 5 RATHER THAN A DISPLAY BUG. JOB-001, JOB-002 and JOB-003
# are all message-mode, and their message IS the hunt instruction the agent acts
# on. An emptied one would fire on schedule and say nothing, and the failure
# would read as the agent ignoring a hunt rather than as a lost field.
#
# THE FILE ALREADY KNOWS HOW TO DO THIS, two lines earlier, for the other radio:
#
#   169  const startsMonitor = !job || (job.schedule || "") === "monitor";
#   170  makeRadio(kindRow, kindName, "monitor", "Monitor", startsMonitor);
#
# The kind radio derives its state from the job. The mode radio does not. That
# is what makes this an omission rather than a design decision.
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
use JSON::PP ();
use Tira;
use Tira::CLI::Browser;

# --- the page is given what it needs ------------------------------------------
#
# FIRST, because it decides where the fix belongs. If the provider withheld the
# mode or the message, this would be a server-side card and the JS would be
# innocent. It does not, so the fault is entirely in the editor - and this
# assertion is what stops somebody "fixing" the provider.

my ( $tira, $root, $message_job, $command_job );
{
    my $tmp = tempdir( CLEANUP => 1 );
    $root = File::Spec->catdir( $tmp, 'board' );
    $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Jobs', dir => $root,
        members => ['claude'], columns => ['backlog, done'],
        sow_prefix => 'JBS', epic_prefix => 'JBE', ticket_prefix => 'JBT',
    );
    $message_job = $tira->job_add( project => $root, schedule => '0 * * * *',
        message => 'HOURLY HUNT - the instruction', author => 'claude' );
    $command_job = $tira->job_add( project => $root, schedule => '*/30 * * * *',
        command => 'd2 tira.police.outstanding', author => 'claude' );

    my %provider = Tira::CLI::Browser::providers( tira => $tira, project => $root );
    ok( ref $provider{jobs} eq 'CODE', 'the jobs provider is there to call' );

    # The provider answers the page in JSON, as a string - it is written for a
    # browser, not for a Perl caller. Decoding rather than dereferencing is the
    # difference between testing what the page receives and testing a shape I
    # assumed it had.
    my $answer = $provider{jobs}->( {} );
    my $decoded = ref $answer ? $answer : JSON::PP->new->decode($answer);
    my $listed = ref $decoded eq 'HASH'
      ? ( $decoded->{jobs} || $decoded->{items} ) : $decoded;

    my ($message_seen) = grep { ( $_->{id} // '' ) eq $message_job->{id} } @{ $listed || [] };
    my ($command_seen) = grep { ( $_->{id} // '' ) eq $command_job->{id} } @{ $listed || [] };

    # non-empty is the whole claim: an empty listing would make both assertions
    # below vacuous and report a server-side gap that is not there.
    ok( $message_seen && $command_seen, 'both jobs came back to the page' );

    is( ( $message_seen || {} )->{mode}, 'message',
        'THE PAGE IS TOLD THE MODE. So the editor opening on Command is not the '
          . 'provider withholding it - the data is there and the form does not '
          . 'ask' );

    is( ( $message_seen || {} )->{message}, 'HOURLY HUNT - the instruction',
        'and it is told the message, in full - so an empty box is not an empty '
          . 'field' );

    is( ( $command_seen || {} )->{command}, 'd2 tira.police.outstanding',
        'and a command job carries its command, which is the half that already '
          . 'works and must go on working' );
}

# --- and the editor reads it --------------------------------------------------
#
# Source assertions, which is how this project tests jobs-editor.js - t/510,
# t/517, t/500 and t/508 all read it as text. The suite does not drive a browser;
# browser tests are his. That makes these weaker than a rendered assertion and
# the file says so rather than implying otherwise.
#
# SCOPED TO THE EDITOR REGION, deliberately. job.mode and job.message both appear
# elsewhere in this file - line 495 renders them onto the CARD - so a whole-file
# grep would pass today and prove nothing. That is the trap t/523 fell into this
# morning, where five assertions passed against unfixed code because the string
# appeared in a comment.

my $editor = Suite::view_source('jobs-editor.js');

my ($region) = $editor =~ /(const \s startsMonitor .*? payload\.command \s* = )/xs;

# non-empty is the whole claim: a region that failed to extract would make every
# assertion below either vacuously true or falsely red.
ok( defined $region && length $region,
    'the editor region was extracted - from the kind radio down to the save '
      . 'payload, which is the form that builds and reads the fields' );

like( $region // '', qr/startsMonitor/,
    'and it contains the KIND radio, which already derives its state from the '
      . 'job: !job || (job.schedule || "") === "monitor". That is the pattern '
      . 'the mode radio does not follow, and its presence here proves the '
      . 'region is the right one' );

unlike( $region // '', qr/"Command"\s*,\s*true\s*\)/,
    'THE MODE RADIO NO LONGER HARDCODES ITS STATE. Today it is '
      . 'makeRadio(..., "Command", true) and makeRadio(..., "Message", false), '
      . 'so every job opens showing Command whatever it is - the form does not '
      . 'ask what mode the job has' );

like( $region // '', qr/job\.mode/,
    'and the region consults job.mode, the way the kind radio consults '
      . 'job.schedule' );

like( $region // '', qr/job\.message/,
    'AND THE TEXT FIELD IS FILLED FROM job.message. Today the single input is '
      . 'filled from job.command whatever the job is, and read into '
      . 'payload.message on save - so a message job shows an empty box and '
      . 'saving writes that empty box over the stored message' );

done_testing();

__END__

=head1 NAME

528-a-form-that-misreports-what-a-job-is.t - the jobs editor and job.mode

=head1 WHY

TKT-914. The jobs editor never reads C<job.mode> on load. The mode radio is
hardcoded to Command, and the single text input is filled from C<job.command>
whatever the job is - so a message job opens showing Command with an empty box,
and a save writes that empty box over the stored message. C<JOB-001>, C<JOB-002>
and C<JOB-003> are all message-mode and their message is the hunt instruction.

=head1 WHAT IS ASSERTED

That the page is B<given> the mode and the message by the C<jobs> provider,
which is what places the fault in the editor rather than the server, and which
stops a later fix being aimed at the provider.

Then that the editor region - from the kind radio to the save payload - stops
hardcoding the mode radio, consults C<job.mode>, and fills the field from
C<job.message>.

=head1 WHAT IS NOT ASSERTED, AND WHY

That the rendered form actually shows the right thing. This project tests
C<jobs-editor.js> by reading it as source, the way F<t/510>, F<t/517>, F<t/500>
and F<t/508> do; the suite drives no browser and browser tests are his. A source
assertion can be satisfied by code that reads C<job.mode> and still renders
wrongly, and saying so here is more use than pretending the coverage is stronger
than it is.

The assertions are scoped to the editor region for a specific reason:
C<job.mode> and C<job.message> both appear later in this file, where the B<card>
is rendered. A whole-file grep would pass today.

=cut
