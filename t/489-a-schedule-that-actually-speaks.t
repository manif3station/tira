#!/usr/bin/env perl
# The half of EPC-014 that makes the record do anything: a police rule that
# announces a due repeated job on the bridge.
#
# TKT-836 shipped the record, the cron evaluation and the due-check. Nothing
# reads them, so a schedule on the board is still just a row in a file - and
# a schedule nobody acts on is exactly as useful as the in-session loops that
# died silently on 2026-09-02, which is what this epic exists to replace.
# TKT-838.
#
# WRITTEN RED, before the rule exists.
#
# ONCE PER DUE WINDOW, NOT ONCE PER PASS. Every other bridge rule here
# settles - task-changed says a thing once, agent-still stamps what it
# notified - because a rule that repeats every pass makes the bridge
# unreadable, and an unreadable bridge is the same failure as a silent one
# wearing different clothes. That is the assertion this file exists for.
#
# THIS CARD ANNOUNCES AND DOES NOT EXECUTE. A command-mode job is left alone
# here; running it is TKT-841, so the execution surface arrives with its own
# tests rather than as a side effect of this one. Asserted, so the boundary
# cannot erode quietly.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = File::Temp::tempdir( CLEANUP => 1 );
my $root  = File::Spec->catdir( $tmp, 'board' );
my $store = File::Spec->catdir( $tmp, 'store' );

# A fixed clock per block, so "is it due" is a statement about the schedule
# rather than about when the suite happened to run. Each time-shifted block
# builds its own Tira with its own clock: a lexical cannot be localised, and
# the first draft tried, which is a compile error rather than a test failure.
my $tira = Tira->new( clock => sub {'2026-09-02T05:00:00Z'} );

$tira->project_new(
    name => 'Scheduled', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'SCS', epic_prefix => 'SCE', ticket_prefix => 'SCT',
);
$tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );

# ANNOUNCED means reported AND not quiet. police_pass keeps returning a
# finding that the ledger has already spoken about, with quiet => 1 on it -
# that is how the escalation ladder works, and it is what stops the bridge
# repeating itself. The first draft of this helper ignored the flag and
# asserted the finding was absent, which made a working rule look broken:
# the mechanism was right and the assertion was wrong about what "announce"
# means.
sub announced {
    my ($on) = @_;
    $on //= $tira;
    my $pass = $on->police_pass( project => $root, store => $store );
    my @rows = grep { ( $_->{rule} // '' ) eq 'job-due' && !$_->{quiet} }
      @{ $pass->{violations} // $pass->{findings} // [] };
    return \@rows;
}

# --- a due message job is announced, in its own words -----------------------

{
    $tira->job_add( project => $root, schedule => '0 * * * *',
        message => 'go hunt some bugs' );

    my $found = announced();
    is( scalar @{$found}, 1, 'a due message-mode job is reported once' );
    like( $found->[0]{detail} // $found->[0]{message} // '',
        qr/go hunt some bugs/,
        'and the announcement carries the job\'s own message, not a generic reminder' );
}

# --- and does not say it again in the same due window -----------------------
#
# The assertion this file exists for. A rule that repeats every pass makes
# the bridge unreadable, which is the same failure as silence.

{
    is( scalar @{ announced() }, 0,
        'a second pass in the same due window announces nothing' );
    is( scalar @{ announced() }, 0, 'and a third stays quiet too' );
}

# --- but does speak again when it next comes due ----------------------------

{
    my $later = Tira->new( clock => sub {'2026-09-02T06:00:00Z'} );
    is( scalar @{ announced($later) }, 1,
        'the next due window announces again - settling is per window, not for ever' );
}

# --- disabled and monitor jobs are silent -----------------------------------

{
    my $off = $tira->job_add( project => $root, schedule => '0 * * * *', message => 'quiet' );
    $tira->job_update( project => $root, id => $off->{id}, enabled => 0 );

    $tira->job_add( project => $root, schedule => 'monitor',
        command => 'd2 tira.policy.bridge' );

    my $later = Tira->new( clock => sub {'2026-09-02T07:00:00Z'} );
    my $rows = announced($later);
    my $text = join ' ', map { $_->{detail} // $_->{message} // '' } @{$rows};

    # The denials below say a particular job is absent, and an empty pass
    # would satisfy them for the wrong reason - t/147's whole subject. So the
    # subject is established first: this pass DID announce something, and
    # what it announced is the third job, not the two that must stay quiet.
    is( scalar @{$rows}, 1,
        'the pass announced exactly one job, so the denials below have a subject' );
    like( $text, qr/go hunt some bugs/,
        'and it is the enabled cron job - which is what makes the two silences meaningful' );
    unlike( $text, qr/quiet/, 'a disabled job is never announced' );
    unlike( $text, qr/policy\.bridge/,
        'and a monitor job is not announced either - it runs continuously rather than on a tick' );
}

# --- this rule announces; it does not execute -------------------------------
#
# TKT-841 owns running a command. Asserted here so the boundary cannot erode
# quietly into "the rule already had the job in hand, so it may as well".

{
    my $engine = do {
        open my $fh, '<:raw', 'lib/Tira.pm' or die $!;    # t/486 marker: about this file, not its code
        local $/;
        <$fh>;
    };
    my ($block) = $engine =~ /\Qeq 'job-due'\E(.*?)\n        \}/s;
    ok( $block, 'the job-due rule body can be found to be checked' );
    unlike( $block // '', qr/(?<![.\w])(?:system|exec|qx)\s*[\(\{]/,
        'and it runs nothing - announcing is this card, executing is TKT-841' );
}

done_testing();

__END__

=head1 NAME

t/489-a-schedule-that-actually-speaks.t - the police rule that announces a due job

=head1 DESCRIPTION

TKT-838. The half of EPC-014 that makes a repeated job do something: when a
job comes due, its message reaches the bridge the agent reads.

The assertion worth keeping is that it announces B<once per due window> and
not once per pass. Every other bridge rule settles, because a rule that
repeats every pass makes the bridge unreadable - and an unreadable bridge
fails the same way a silent one does, which is the failure this whole epic
was filed to end.

It also asserts the rule executes nothing. Running a command-mode job is
TKT-841, so the execution surface arrives with its own tests rather than as a
side effect of this rule already having the job in hand.

=cut
