#!/usr/bin/env perl
# The jobs editor offers two things Tira::Job::_job_fields refuses.
#
# TKT-929. TKT-911 and TKT-912 each found the same shape a different day, and
# the two lists were compared rather than waiting for a third: _job_fields
# makes FIVE refusals, and the form now declines three of them by
# construction (schedule, command-or-message, monitor-with-message). These
# are the other two.
#
# ONE: AN INTERVAL THE ENGINE WILL REJECT. min="2" on the seconds field is a
# measured floor about the feeder's quiet window, not the engine's own rule -
# the engine wants a whole number of seconds greater than zero - so a pasted
# "2.5", a scripted "0", or an empty box with the checkbox ticked used to
# reach the save and come back as an error over a form that looked complete.
#
# TWO: A MONITOR WITH NO COMMAND, WHICH ONLY THE BROWSER OBJECTS TO. judge()
# disables Save when the command field is empty, and that is the whole of it
# on the page - but the SAVE PATH (the job_save provider) is reachable by
# anything that can POST, not only by a form judge() has approved. This half
# is proved against the provider directly, not the DOM.
#
# THE MAPPING, so a sixth refusal has an obvious place to be checked against:
#   1. schedule required................. the schedule box itself, always filled
#   2. command or message, not neither.... judge() disables Save on an empty command
#   3. not both at once.................. the form never offers both fields at once
#   4. monitor refuses a message.......... applyKind() hides the message field for monitor
#   5. restart_every: whole seconds > 0... THIS CARD, client-side, quoting the engine
#   (a monitor with no command, reached via POST rather than the form, is
#   refusal #2 again - already covered by job_add calling _job_fields - and
#   is proved here directly against the provider.)
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite;
use Tira;

require Tira::Job;
require Tira::CLI::Browser;

# --- ONE: the interval, checked against the engine's own rule ---------------

my $js = Suite::view_source('jobs-editor.js');

# non-empty is the whole claim: the assertions below read this file, and an
# unreadable one would fail them for the wrong reason.
like( $js, qr/\S/, 'the jobs editor is there to be read' );

like(
    $js,
    qr/\[1-9\]\[0-9\]\*/,
    'THE PAGE CHECKS THE SAME PATTERN THE ENGINE DOES - a whole number of '
      . 'seconds greater than zero - not just the measured min="2" floor'
);

like(
    $js,
    qr/whole number of seconds,.{0,40}greater than zero/s,
    'AND QUOTES THE ENGINE\'S OWN WORDS rather than inventing a second '
      . 'wording that could drift from Tira::Job::_job_fields'
);

my $engine = Suite::engine_source();
like(
    $engine,
    qr/whole number of seconds,.{0,40}greater than zero/s,
    'and that phrase is genuinely the engine\'s - not merely quoted, but '
      . 'quoted CORRECTLY'
);

# --- TWO: a monitor with no command, proved against the provider -----------

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new( clock => sub { '2026-09-05T03:00:00Z' } );
$tira->project_new(
    project => $root, name => 'Guarded', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'GDS', epic_prefix => 'GDE', ticket_prefix => 'GDT',
);

my %provider = Tira::CLI::Browser::providers( tira => $tira, project => $root );
ok( ref $provider{job_save} eq 'CODE', 'the page has a provider it saves jobs through' );

{
    my $refused = !eval {
        $provider{job_save}->( { schedule => 'monitor' } );
        1;
    };
    ok( $refused,
        'A MONITOR WITH NO COMMAND IS REFUSED BY THE PROVIDER ITSELF - called '
          . 'directly, bypassing judge() and the disabled-Save button entirely' )
      or diag('job_save created a monitor with nothing to run');
    like( $@, qr/command.{0,20}message|message.{0,20}command/i,
        'naming the actual rule (needs a command or a message) rather than a '
          . 'generic failure' );
}

is( scalar @{ $tira->job_list( project => $root ) }, 0,
    'and nothing was written to the board by the refused attempt' );

done_testing();

__END__

=head1 NAME

547-two-refusals-the-page-still-lets-through.t - the interval field and a commandless monitor, both reachable past the page's own checks

=head1 WHY

TKT-929. Comparing C<Tira::Job::_job_fields>' five refusals against what the
jobs editor already declines by construction (TKT-911, TKT-912) found two
gaps: a restart interval the browser's min="2" does not actually validate
against the engine's real rule, and a monitor with no command, which only a
disabled Save button objects to - the save path itself is reachable by
anything that can POST.

=head1 WHAT IS ASSERTED

That the page checks the interval against the engine's own pattern and
words, verified against the engine's real source so the two cannot quietly
drift apart; and that the job_save provider refuses a monitor with no
command when called directly, bypassing the DOM entirely.

=cut
