#!/usr/bin/env perl
# TKT-1023. Michael's TG msg #7797, live, photo attached: clicking Run now on
# a message-mode job produced no visible feedback - "Run now does nothing."
#
# ROOT CAUSE: Tira::CLI::Police::run_due_job explicitly no-ops for a
# message-mode job ("A message-mode job is announced by the engine and runs
# nothing") - true for the DUE PASS, which announces it through the job-due
# rule before run_due_job is ever reached, but run_now (the Run now button's
# executor) calls run_due_job directly with no due-pass rule behind it, so a
# manual click on a message-mode job reached that exact same no-op and looked
# identical to a broken button.
#
# HIS DECISION (Q-148, answered live): announce the message to the bridge
# immediately.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

require Tira::CLI::Job;
require Tira::CLI::Police;

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $store = File::Spec->catdir( $tmp, 'store' );

my $tira = Tira->new( clock => sub {'2026-09-09T09:07:17Z'} );
$tira->project_new(
    name => 'Played', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'PLS', epic_prefix => 'PLE', ticket_prefix => 'PLT',
);

my $job = $tira->job_add(
    project => $root, schedule => '0 3 1 1 *', mode => 'message',
    message => 'his own words: run now does nothing',
);

# --- before: the backlog is empty -------------------------------------------
#
# A harmless first write seeds the store before either count: bridge_backlog
# prefixes a one-time "replaying N outstanding..." header on a store's first
# ever read, which would otherwise show up as a false +1 on "before" alone
# (t/590's own documented reason for the same seed).
$tira->bridge_write( store => $store, violations => [ {
    id => 'VIO-0000', ref => 'PLT-000', rule => 'card-stalled',
    detail => 'seed', action => 'bridge-reminder', tone => 'note' } ] );
my $before = $tira->bridge_backlog( store => $store, lines => 1000 );

# --- Run now on a message-mode job ------------------------------------------

my ($before_run) = grep { $_->{id} eq $job->{id} } @{ $tira->job_list( project => $root ) };
ok( !defined $before_run->{last_run_at}, 'and last_run_at is unset before any manual run' );

my $outcome = Tira::CLI::Job::run_now( $tira, { project => $root, store => $store, id => $job->{id} } );

is( ( $outcome->{ran} // 0 ), 1,
    'Run now on a message-mode job reports that something happened - not the old silent ran=>0' );

my ($after_run) = grep { $_->{id} eq $job->{id} } @{ $tira->job_list( project => $root ) };
ok( defined $after_run->{last_run_at},
    'and last_run_at is now stamped - the same helper (record_run/job_ran) a command-mode click has '
      . 'always gone through, so the card stops reading "Never fired" about a job he just pressed' );

my $after = $tira->bridge_backlog( store => $store, lines => 1000 );
is( scalar( @{$after} ) - scalar( @{$before} ), 1,
    'and the bridge backlog gains exactly one line - the message reached the bridge, not nowhere' );

my @entries = grep { /\Q$job->{id}\E/ } @{$after};
is( scalar @entries, 1, 'and it names this exact job' );
like( $entries[0] // '', qr/run now does nothing/,
    'and carries his own message text, not a generic "ran" line' );

# --- a second click is a second, honest announcement, not silence ----------

my $again = Tira::CLI::Job::run_now( $tira, { project => $root, store => $store, id => $job->{id} } );
is( ( $again->{ran} // 0 ), 1, 'a second click also reports it ran' );
my $after2 = $tira->bridge_backlog( store => $store, lines => 1000 );
is( scalar( @{$after2} ) - scalar( @{$after} ), 1,
    'and a second manual click announces again - a person clicking twice is not told it happened once' );

# --- an announcement that genuinely cannot be written is REPORTED, not eaten -
#
# store => '' is defined but falsy: run_now's own `$args->{store} //
# _police_store(...)` keeps it (// only checks definedness), and bridge_
# log_path then dies "A police store is required" - a real failure, not a
# contrived mock, reaching run_now's own eval/or-do failure branch.

my $unwritable_job = $tira->job_add(
    project => $root, schedule => '0 3 1 1 *', mode => 'message',
    message => 'this one can never be announced',
);
my $failed_announce = Tira::CLI::Job::run_now(
    $tira, { project => $root, store => '', id => $unwritable_job->{id} } );
is( ( $failed_announce->{ran} // 1 ), 0,
    'a genuine failure to announce is reported as not having run' );
like( ( $failed_announce->{output} // '' ), qr/could not announce the message/,
    'and says why, rather than reading as a silent success' );

# --- command-mode Run now is unaffected -------------------------------------

my $command_job = $tira->job_add(
    project => $root, schedule => '0 3 1 1 *', mode => 'command',
    command => 'perl -e print+1',
);
my $ran = Tira::CLI::Job::run_now( $tira, { project => $root, store => $store, id => $command_job->{id} } );
is( ( $ran->{ran}    // 0 ),  1, 'a command-mode job still runs on demand, exactly as before' );
is( ( $ran->{status} // -1 ), 0, 'and reports its exit status, unaffected by this fix' );
like( ( $ran->{output} // '' ), qr/1/, 'and its own output, unaffected by this fix' );

done_testing();

__END__

=head1 NAME

t/1023-a-play-button-that-played-nothing.t - Run now on a message-mode job
announces the message, rather than silently doing nothing

=head1 DESCRIPTION

TKT-1023. C<Tira::CLI::Police::run_due_job> no-ops for a message-mode job -
correct for the scheduled due pass, which already announces it through the
C<job-due> rule before C<run_due_job> is ever reached, but C<run_now> (the
browser's Run now button) calls C<run_due_job> directly with no due-pass rule
behind it, so a manual click reached that same silent no-op and read as a
broken button.

Fixed in C<Tira::CLI::Job::run_now>: a message-mode job now writes its own
bridge announcement directly, via C<bridge_write>, B<not> through
C<violation_record> - that ledger's own quiet ladder exists to stop a
I<standing> problem repeating on every pass, and would have silently
swallowed a second identical manual click, the opposite of what "announce
immediately" asked for.

=cut
