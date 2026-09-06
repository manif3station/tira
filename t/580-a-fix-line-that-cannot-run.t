#!/usr/bin/env perl
# TKT-866, found by the hourly bug hunt on 2026-09-02 from a line the job-due
# rule had printed on the bridge minutes earlier - and still printing it today,
# four days later, on this project's own board.
#
# EVERY VIOLATION CARRIES A 'fix:' LINE and its whole purpose is to hand the
# reader a command they can paste. For a job or a task it hands them one that
# fails:
#
#   VIO-2562 | JOB-001 | job-due     | fix: d2 tira.ticket.show --ref JOB-001
#   VIO-2556 | TSK-434 | task-changed | fix: d2 tira.ticket.show --ref TSK-434
#
# Run verbatim, both answer "Record 'JOB-001' not found" and exit 2. Confirmed
# again on the live board while writing this: ticket.show refuses JOB-001 and
# TSK-519, and ACCEPTS EPC-007 - it resolves a card by ref across boards.
#
# WHY IT HAPPENS, read rather than guessed. The report closure takes either a
# record or a bare id:
#
#   my $ref = ref $record ? $record->{ref} : ( $record // '' );
#
# job-due calls it with $job->{id}, a plain string. The distinction is made
# right there and then thrown away, because only the ref is stored - so
# _violation_fix sees a non-empty ref that is not SOW- or EPC- prefixed and
# emits tira.ticket.show for it.
#
# A CORRECTION TO THE CARD, which said jobs, tasks AND questions. Questions are
# fine: question-unanswered reports with the RECORD and passes the question id
# as a sub_key, so its ref is the card's and the fix line works. Read before
# asserting, because a test written from the card would have claimed a defect
# that is not there.
#
# JOB- and TSK- ARE SAFE TO MATCH ON, unlike card prefixes: jobs and tasks are
# numbered by the engine with sprintf 'JOB-%03d' and 'TSK-%03d', while a card's
# prefix is per-project and configurable.
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
use Tira::CLI;
use Tira::CLI::Police;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $now  = '2026-09-06T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Fix Line', dir => $root, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'FLS', epic_prefix => 'FLE', ticket_prefix => 'FLT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ), \$now );
}

# THE PRINTED LINE IS RUN, NOT MATCHED. CHK-005 asks for exactly this, and it
# is the difference between checking the wording and checking the promise: the
# fix line's whole claim is that a reader can paste it, so the test pastes it.
#
# The d2 wrapper is not in this container, so the line is dispatched the way
# t/70-doc-examples.t already dispatches every documented example - through
# Tira::CLI->run, with TIRA_HOME pointing at the fixture. An unknown command
# dies there exactly as it would exit 2 on the terminal, which is the failure
# this card is about.
sub run_fix_line {
    my ( $tira, $root, $line ) = @_;
    my @argv = split /\s+/, ( $line // '' );
    shift @argv if @argv && $argv[0] eq 'd2';
    my $command = shift @argv // '';
    $command =~ s/\Atira\.//;
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;

    my ( $out, $err ) = ( '', '' );
    open my $oh, '>', \$out or die $!;
    open my $eh, '>', \$err or die $!;
    my $old = select $oh;

    # THE EXIT STATUS, NOT MERELY THAT IT RETURNED. Tira::CLI->run answers with
    # the code the terminal would exit on and does NOT die for a record it
    # cannot find - so an eval that only asks "did it survive" reports the
    # broken line as working. The first version of this helper did exactly
    # that and turned test 4 green against the unfixed code, which is the
    # asking-the-wrong-question fault this suite has been bitten by before.
    my $status = eval {
        local $ENV{TIRA_HOME} = $root;
        local *STDERR = $eh;
        Tira::CLI->run( command => $command, ( defined $type ? ( type => $type ) : () ),
            argv => \@argv, tira => $tira );
    };
    my $died = $@ // '';
    select $old;
    my $ok = !$died && !( $status // 0 );
    return ( $ok, ( $err . $died . ( defined $status ? " (exit $status)" : '' ) ) );
}

sub fixes_by_rule {
    my ( $tira, $root, $store ) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
    my %fix;
    for my $violation ( @{ $pass->{violations} || [] } ) {
        $fix{ $violation->{rule} // '?' } =
          Tira::_violation_fix($violation) . "\x00" . ( $violation->{ref} // '' );
    }
    return \%fix;
}

# --- a job's fix line names a job command ----------------------------------
#
# The whole card. job-due reports with the job's id, so the reader is handed a
# command about a record that does not exist.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
    $tira->job_add( project => $root, schedule => '* * * * *',
        message => 'go and hunt some bugs' );

    ${$clock} = '2026-09-06T09:30:00Z';
    my ( $fix, $ref ) = split /\x00/, ( fixes_by_rule( $tira, $root, $store )->{'job-due'} // '' );

    is( $ref, 'JOB-001', 'the finding is about the job, which is why its ref is a job id' );
    unlike( $fix // '', qr/ticket\.show/,
        'and its fix line does NOT offer tira.ticket.show for a job - that command answers '
          . '"Record not found" and exits 2, which is worse than no suggestion at all' );
    like( $fix // '', qr/\bjob\b/,
        'it offers a job command instead, so the line can be pasted' );

    my ( $ran, $said ) = run_fix_line( $tira, $root, $fix );
    ok( $ran, 'and RUNNING that line succeeds - the promise a fix line makes is that it can '
          . 'be pasted, so this test pastes it rather than reading it' )
      or diag("the fix line was: $fix\n$said");
}

# --- and a task's names a task command --------------------------------------
#
# The second half of what he observed on the bridge, and it fails the same way
# for the same reason.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->policy_add( project => $root, rule => 'task-unlinked',
        action => 'bridge-reminder', age => '10m' );
    $tira->tasklist_add( project => $root, text => 'a note nobody tied to a card' );

    ${$clock} = '2026-09-06T09:30:00Z';
    my ( $fix, $ref ) = split /\x00/,
      ( fixes_by_rule( $tira, $root, $store )->{'task-unlinked'} // '' );

    like( $ref // '', qr/\ATSK-/, 'the finding is about the task, so its ref is a task id' );
    unlike( $fix // '', qr/ticket\.show/,
        'and its fix line does not offer tira.ticket.show for a task either' );
    like( $fix // '', qr/tasklist/,
        'it offers a tasklist command, which is a command that exists for the thing named' );

    my ( $ran, $said ) = run_fix_line( $tira, $root, $fix );
    ok( $ran, 'and running it succeeds' ) or diag("the fix line was: $fix\n$said");
}

# --- a card's fix line is unchanged -----------------------------------------
#
# The direction a careless fix breaks. Cards are the common case and their fix
# line already works, including for epics and SOWs.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card with no parent' );

    ${$clock} = '2026-09-06T09:30:00Z';
    my ( $fix, $ref ) = split /\x00/,
      ( fixes_by_rule( $tira, $root, $store )->{'orphan-card'} // '' );

    is( $ref, $card->{ref}, 'the finding is about the card' );
    like( $fix // '', qr/\Qticket.show --ref $card->{ref}\E/,
        'and its fix line still points at the card, which is what a reader wants and what '
          . 'already worked' );

    my ( $ran, $said ) = run_fix_line( $tira, $root, $fix );
    ok( $ran, 'and it still runs, which is the half that was never broken' )
      or diag("the fix line was: $fix\n$said");
}

# --- a board-level finding still points at the policies ---------------------
#
# A rule with no ref at all falls through to tira.policy.list, which runs. That
# fallback must survive.

{
    my $fix = Tira::_violation_fix( { rule => 'board-still' } );
    is( $fix, 'd2 tira.policy.list',
        'a finding with no ref still points at the policy list, which is a command that runs' );
}

# --- a rule that names its own remedy still wins -----------------------------
#
# card-damaged and board-unbacked name a command rather than a card, and that
# lookup is asked first. This card must not disturb it.

{
    is( Tira::_violation_fix( { rule => 'card-damaged', ref => 'FLT-001' } ),
        'd2 tira.doctor --repair',
        "a rule with its own remedy still wins over the card, because pointing at a card is "
          . 'a good default and a bad answer when there is a command to run' );
    is( Tira::_violation_fix( { rule => 'board-unbacked' } ), 'd2 tira.backup',
        'and so does the one that knows how to back the board up' );
}

# --- questions were never broken --------------------------------------------
#
# The card said jobs, tasks AND questions. Questions are fine, and asserting
# that keeps a later change from "fixing" something that works: the rule
# reports with the CARD and carries the question id as a sub_key.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->policy_add( project => $root, rule => 'question-unanswered',
        action => 'bridge-reminder', age => '10m' );
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'a card with a question on it' );
    $tira->question_add( project => $root, ref => $card->{ref},
        author => 'claude', text => 'Which way?' );

    ${$clock} = '2026-09-06T09:30:00Z';
    my ( $fix, $ref ) = split /\x00/,
      ( fixes_by_rule( $tira, $root, $store )->{'question-unanswered'} // '' );

    is( $ref, $card->{ref},
        "a question's finding is reported against the CARD, not the question id - which is "
          . 'why its fix line was never one of the broken ones' );
    like( $fix // '', qr/ticket\.show/, 'so it points at the card' );
    my ( $ran, $said ) = run_fix_line( $tira, $root, $fix );
    ok( $ran, 'and running it confirms questions were never one of the broken cases' )
      or diag("the fix line was: $fix\n$said");
}

done_testing();

__END__

=head1 NAME

580-a-fix-line-that-cannot-run.t - every fix line names a command that exists for the thing it is about

=head1 DESCRIPTION

TKT-866. Police attaches a C<fix:> line to every violation so the reader has
something to paste. Rules that report about a job or a tasklist item pass a
bare id where the closure normally receives a record, and C<_violation_fix>
then offers C<tira.ticket.show> for it - a command that answers "Record not
found" and exits 2.

Questions were never affected, despite the card saying so:
C<question-unanswered> reports against the card and carries the question id as
a C<sub_key>, so its fix line points at the card and runs. C<JOB-> and C<TSK->
are safe to recognise because the engine numbers both itself, unlike a card
prefix, which is per-project.

=cut
