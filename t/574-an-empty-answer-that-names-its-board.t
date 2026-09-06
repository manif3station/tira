#!/usr/bin/env perl
# TKT-962. His report: "tira.job.list silently returned an empty list for a
# board with 3 jobs - and I declined four safety rules on that empty read."
#
# THE TWO DECISIONS THAT COMBINE, each defensible alone:
#
#   job_list  resolves its board with discover_project(%args), which searches
#             UPWARD from the working directory when the caller names none.
#   _job_read returns [] when the jobs file is absent.
#
# So a caller standing in the wrong place is answered for whichever board lies
# above them, and if that board never had a job the answer is an empty list -
# with no error and nothing to distinguish it from the board they meant.
#
# THE DAMAGE IS NOT THE EMPTY LIST, IT IS THAT IT LOOKS ORDINARY. An error
# would have stopped the work. A plausible wrong answer did not, and four
# safety rules were declined against it.
#
# SAME PATTERN AS TKT-949, six hours earlier the same night: a board resolved
# from the process's own location, and an absent thing reported as an empty
# one. The bridge panel showed "Nothing on the bridge yet" while the real store
# held 13,037 entries. Two instances make it a pattern, and a sweep found five
# reads in lib/ that treat an absent file as empty.
#
# WHAT THIS FIXES, and deliberately not more. The answer itself must not
# change: -o json emits the underlying payload and callers depend on the list
# being a list. What changes is the SILENCE - an empty answer says which board
# it was empty for, so a caller who is somewhere unexpected sees it. Making the
# read refuse to guess its board at all is the larger half and is not this
# test's business.
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

sub board_with {
    my ($jobs) = @_;
    my $tmp  = tempdir( CLEANUP => 1 );
    my $tira = Tira->new( clock => sub {'2026-09-06T04:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Named Board', dir => $root, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'NBS', epic_prefix => 'NBE', ticket_prefix => 'NBT',
    );
    $tira->job_add( project => $root, schedule => '* * * * *', command => '/bin/true' )
      for 1 .. $jobs;
    return ( $tira, $root );
}

sub list_jobs {
    my ( $tira, $root ) = @_;
    my ( $out, $said ) = ( '', '' );
    {
        local $ENV{TIRA_HOME} = $root;
        open my $oh, '>', \$out  or die $!;
        open my $eh, '>', \$said or die $!;
        local *STDERR = $eh;
        my $old = select $oh;
        eval {
            Tira::CLI->run(
                command => 'job.list', tira => $tira,
                # No --project: it is not an option this CLI takes. The board
                # comes from TIRA_HOME above, which a direct Tira::CLI->run
                # honours even though the d2 wrapper does not.
                argv    => [ '-o', 'toon' ],
            );
            1;
        } or do { $said .= $@ // '' };
        select $old;
    }
    return ( $out, $said );
}

# --- an empty answer says which board it was empty for ---------------------
#
# The whole card. A board with no jobs is a legitimate answer; answering
# without saying whose answer it is, is what let four safety rules go.

{
    my ( $tira, $root ) = board_with(0);
    my ( $out, $said ) = list_jobs( $tira, $root );

    # non-empty is the whole claim: the check below would pass on an
    # unreadable stream's emptiness alone.
    like( $out . $said, qr/\S/, 'the command answered with something' );
    like( $out . $said, qr/Named Board/,
        'an empty jobs answer NAMES the board it was empty for - so a caller who is '
          . 'somewhere unexpected can see that, rather than reading it as "this board has no jobs"' );
}

# --- a board that has jobs answers as before -------------------------------
#
# The regression that would matter most: the note belongs to the empty case
# and must not follow every ordinary listing around.

{
    my ( $tira, $root ) = board_with(2);
    my ( $out, $said ) = list_jobs( $tira, $root );

    like( $out, qr/JOB-001/, 'a board with jobs still lists them' );
    # empty is what passes here, and that is the point: this board HAS jobs, so
    # nothing should have been said about emptiness at all. An empty $said is
    # the correct result rather than an unread stream - the listing above came
    # back on stdout in the same call, which is what proves the command ran.
    unlike( $said, qr/no jobs/i,
        'and says nothing about emptiness, because it was not empty' );
}

# --- the answer itself is unchanged ----------------------------------------
#
# -o json emits the underlying payload and callers depend on the list being a
# list. The silence is what this card fixes, not the shape of the answer.

{
    my ( $tira, $root ) = board_with(0);
    my $jobs = $tira->job_list( project => $root );
    is( ref $jobs, 'ARRAY', 'job_list still returns a plain list' );
    is( scalar @{$jobs}, 0, 'and an empty board still answers with an empty one' );
}

done_testing();

__END__

=head1 NAME

574-an-empty-answer-that-names-its-board.t - an empty jobs answer says which board it was empty for

=head1 DESCRIPTION

TKT-962. C<job_list> resolves its board from the working directory when the
caller names none, and C<_job_read> returns an empty list when the jobs file is
absent. Together they answer confidently for the wrong board: the owner was
given an empty list for a board with three jobs, and declined four safety rules
against it.

The answer's shape is unchanged - C<-o json> still emits a list and callers
depend on it. What changes is that an empty answer names the board it was empty
for, so a caller standing somewhere unexpected can see that rather than reading
it as "this board has no jobs".

=cut
