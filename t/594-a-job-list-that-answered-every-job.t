#!/usr/bin/env perl
# TKT-984. Reported through tira.dev.found.bug_or_improvement: d2
# tira.job.list --id JOB-NNN returned the FULL unfiltered job list, not just
# that one job. Confirmed by reading the source rather than guessing: job.list's
# CLI dispatch already builds %list = %{$args} - --id is in the hash by the
# time it reaches Tira::Job::job_list - but job_list itself never reads
# $args{id} at all, only $args{store}. Its own --help usage line
# ("Usage: d2 tira.job.list [-o FORMAT]") never claimed --id either, so the
# flag parsed cleanly and did nothing - the same shape as TKT-625's ignored
# --dry-run.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $tira = Tira->new( clock => sub {'2026-09-07T09:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Job Filter', dir => $root, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'JFS', epic_prefix => 'JFE', ticket_prefix => 'JFT',
    );
    return ( $tira, $root );
}

my ( $tira, $root ) = board();
my $one = $tira->job_add( project => $root, schedule => '0 * * * *', command => 'd2 tira.police.outstanding' );
my $two = $tira->job_add( project => $root, schedule => '0 * * * *', command => '/bin/true' );
my $three = $tira->job_add( project => $root, schedule => '0 * * * *', command => '/bin/false' );

# --- --id filters to exactly one job -----------------------------------------

my $filtered = $tira->job_list( project => $root, id => $one->{id} );
is( scalar @{$filtered}, 1, '--id returns exactly one job, not the full list' );
is( $filtered->[0]{id}, $one->{id}, 'and it is the job that was asked for' );

# --- an unknown --id refuses by name, not an empty or full list -------------

my $error = eval { $tira->job_list( project => $root, id => 'JOB-999' ); 1 } ? undef : $@;
ok( defined $error, 'an --id naming no job refuses rather than answering silently' );
like( $error // '', qr/JOB-999/, 'and names the id that was not found' );

# --- omitting --id is unchanged: the full list, exactly as before -----------

my $unfiltered = $tira->job_list( project => $root );
is( scalar @{$unfiltered}, 3, 'no --id still returns every job, unchanged' );

done_testing();

__END__

=head1 NAME

594-a-job-list-that-answered-every-job.t - job.list --id filters to one job

=head1 DESCRIPTION

TKT-984. C<job_list> accepted C<--id> (it was already in the argument hash
C<job.list>'s own CLI dispatch builds) but never read it, silently returning
every job regardless. Fixed at C<Tira::Job::job_list>: given C<id>, it returns
exactly that one job, refusing by name when no job carries it - the same
shape C<job_update>'s own C<_job_find> already uses - rather than an empty or
full list standing in for "not found". Omitting C<--id> is unchanged.

=cut
