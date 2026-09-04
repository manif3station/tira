#!/usr/bin/env perl
# A jobs record that cannot be read, and the rule that says nothing about it.
#
# TKT-899, EPC-014. `job-due` reads the jobs record without guarding the read, so
# a jobs file that cannot be read makes every due job silently invisible - and
# the pass reports nothing at all.
#
#     lib/Tira.pm  for my $job ( @{ $self->job_list( project => $root ) } ) {
#
# EVERY OTHER RULE THAT READS THAT RECORD GUARDS IT. monitor-dead,
# monitor-output and monitor-silent each wrap the call, check for a failure, and
# REPORT it. The reasoning is written out beside monitor-dead:
#
#     "Swallowing a read failure into 'there are no jobs' would make a locked or
#      corrupt jobs file look exactly like a board with no monitors - silence
#      standing in for an answer, which is the precise failure this rule exists
#      to end, rebuilt inside the rule itself."
#
# That is about monitors. It is exactly as true of a due job, and job-due is the
# one rule that does not do it.
#
# WHY THIS IS WORTH A CARD RATHER THAN A SHRUG: the failure is silent in the one
# direction nobody checks. A board whose jobs file has gone unreadable looks
# identical to a board with nothing due - and the whole of EPC-014 exists because
# a schedule nobody can see is a schedule nobody checks.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $store = File::Spec->catdir( $tmp, 'police' );
    my $tira = Tira->new( clock => sub { '2026-09-04T05:00:00+0100' } );
    $tira->project_new(
        name => 'Due', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'DUS', epic_prefix => 'DUE', ticket_prefix => 'DUT',
    );
    $tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
    return ( $tira, $root, $store );
}

# --- a healthy pass still announces a due job -------------------------------
#
# The guard must not cost the thing the rule is for. This is the control: if it
# ever stops passing, the fix has broken the rule rather than protected it.

{
    my ( $tira, $root, $store ) = board();
    $tira->job_add(
        project => $root, schedule => '0 * * * *', message => 'the hunt is due' );

    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    # A violation carries its text in `detail`; `message` is present but empty.
    # Read both rather than guessing - my first version read only `message`, and
    # the control failed with one violation and nothing to show for it, which
    # looked exactly like the rule not firing.
    my @said = map { join ' ', grep { defined && length } @{$_}{qw(message detail)} }
      @{ $pass->{violations} || [] };

    ok( scalar( grep { /hunt is due/ } @said ),
        'a healthy pass announces the due job - the control, so a guard that '
          . 'silenced the rule would fail here rather than look like a fix' )
      or diag( "violations: " . scalar( @{ $pass->{violations} || [] } )
          . " | said: " . join( ' ;; ', @said ) );
}

# --- and an unreadable record is REPORTED, not swallowed --------------------
#
# The record is made unreadable the way it actually goes wrong - the file is
# there and its contents are not what the reader expects - rather than by
# deleting it, which is a board with no jobs and is a different thing.

{
    my ( $tira, $root, $store ) = board();
    $tira->job_add(
        project => $root, schedule => '0 * * * *', message => 'the hunt is due' );

    my $jobs = File::Spec->catfile( $root, '.tira', 'jobs.json' );

    # non-empty is the whole claim: if this path is wrong the test would be
    # corrupting nothing and the assertion below would fail for the wrong reason.
    ok( -e $jobs, 'the jobs record is where this test is about to break it' );

    open my $fh, '>', $jobs or die "$jobs: $!";
    print {$fh} '{ this is not json';
    close $fh;

    my @said;
    my $ok = eval {
        my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
        @said = map { join ' ', grep { defined && length } @{$_}{qw(message detail)} }
          @{ $pass->{violations} || [] };
        1;
    };
    my $why = $@ // '';

    ok( $ok, 'the pass finishes rather than dying - one unreadable record must '
          . 'not take down the pass that would have reported everything else' )
      or diag("it died: $why");

    ok( scalar( grep { /could not be read/i } @said ),
        'AND IT SAYS SO. Today it says nothing at all: the read fails, the loop '
          . 'gets nothing, and a board whose jobs file is corrupt looks exactly '
          . 'like a board with nothing due - silence standing in for an answer, '
          . 'inside a rule whose whole purpose is to end that' );

    ok( scalar( grep { /job/i } @said ),
        'and names what could not be read, so the reader knows which record to '
          . 'go and look at rather than which rule was running' );
}

# --- the four rules that read this record now read it alike ------------------
#
# The value here is sameness rather than cleverness. Three rules already carry
# this guard in an identical shape; a fourth guard written differently would be
# a second thing to keep in agreement, which is how the two validators for one
# format went wrong on TKT-713.

{
    my $engine = do {
        open my $fh, '<:raw', File::Spec->catfile( 'lib', 'Tira.pm' ) or die $!;
        local $/;
        <$fh>;
    };

    # non-empty is the whole claim: an unreadable file would report every count
    # as zero and pass the comparison below by accident.
    like( $engine, qr/\S/, 'the engine source was read to count the guards' );

    my $guards = () = $engine =~ /my \$jobs = eval \{ \$self->job_list/g;

    cmp_ok( $guards, '>=', 4,
        'FOUR RULES READ THE JOBS RECORD AND ALL FOUR GUARD IT. Three did '
          . 'before this card, in an identical shape; the fourth is the one this '
          . 'card is about, and it is written the same way rather than better - '
          . 'a second shape would be a second thing to keep in agreement' );

    unlike( $engine, qr/for my \$job \( \@\{ \$self->job_list\(/,
        'and no rule reads it bare any more - the unguarded loop is gone rather '
          . 'than joined by a guarded one somewhere else in the file' );
}

done_testing();

__END__

=head1 NAME

521-a-due-job-nobody-could-see.t - the fourth rule that reads the jobs record

=head1 WHY

TKT-899. C<job-due> read the jobs record unguarded, so a record that could not be
read made every due job invisible and the pass said nothing. The other three
rules that read it - C<monitor-dead>, C<monitor-output>, C<monitor-silent> - each
wrap the read and report the failure.

=head1 WHAT IS ASSERTED

That a healthy pass still announces a due job, which is the control; that an
unreadable record is reported rather than swallowed, and that the pass finishes
rather than dying of it; and that all four rules now read that record in the same
shape, with no bare read left in the engine.

=cut
