#!/usr/bin/env perl
# A report somebody else filed does not stop this project shipping.
#
# Another project files a fault through tira.dev.found.bug_or_improvement. The
# command fills a title, a description, a source and a reporter - that is all it
# can, because the reporter knows what they saw and not how this project will
# fix it. The push gate then asks that card what it asks a ticket somebody is
# working: a problem statement, a solution, deliverables, acceptance criteria,
# test steps, BDD, ATDD, a checklist, scope and a parent.
#
# So a release that has passed its suite and its coverage waits on somebody
# writing up somebody else's report. Measured on 2026-08-15: the card check
# named three inbound reports, I wrote all three up, and the next run named
# three more that had arrived while I was writing - one of them a withdrawal of
# a report I had just spent an hour specifying.
#
# The gate can tell them apart: a reported card carries a source saying where it
# came from. What it cannot do is know when somebody has triaged one, so the
# column does that - a report still in the backlog nobody has touched is asked
# what a report can answer, and the moment it is picked up it is a ticket like
# any other.

use strict;
use warnings;

use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Run qw(run_capturing);
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );
$tira->project_new(
    name => 'Reported', dir => $root, members => ['claude'],
    # A verify column, because the gate refuses a board without one - it has
    # no point past which a card claims to be proven, so its checks cannot say
    # anything and it says so rather than passing quietly. The first version of
    # this test left it out and measured that refusal instead.
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'RPS', epic_prefix => 'RPE', ticket_prefix => 'RPT',
);

# A report, in the shape the reporting command leaves one: a title, a
# description, and a source saying where it came from.
my $report = $tira->create_record(
    project => $root, type => 'ticket',
    title => 'Something is wrong over here',
    description => 'What I saw, and how to see it again.',
    source => 'Reported from another-project through tira.dev.found.bug_or_improvement',
);

# And a card somebody here is working, with nothing on it.
my $mine = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card of my own with nothing on it' );
$tira->record_move( project => $root, ref => $mine->{ref}, column => 'implement' );

my $tool  = File::Spec->rel2abs( File::Spec->catfile( 'tools', 'card-holes' ) );
my $skill = File::Spec->rel2abs('.');

# A dispatcher of its own, because the real one is not here. The gate reaches a
# board through d2, which is the dashboard, and the dashboard is not installed
# in the container the suite runs in - so the first version of this test passed
# on my machine and failed the gate, which is the worst way round. t/217 hit
# the same wall and this is the same stub: it maps a command to an entrypoint
# as the shipped ones do, and it does not rewrite TIRA_HOME, which the real
# dashboard does when the working directory belongs to a project.
my $stub = File::Spec->catdir( $tmp, 'bin' );
mkdir $stub or die "$stub: $!";
{
    my $path = File::Spec->catfile( $stub, 'd2' );
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} <<"PL";
#!$^X
use strict;
use warnings;
use File::Spec;
my \$command = shift \@ARGV;
\$command =~ s/\\Atira\\.//;
my \@parts = split /\\./, \$command;
my \$verb = pop \@parts;
my \$entry = \@parts
  ? File::Spec->catfile( '$skill', 'skills', \@parts, 'cli', \$verb )
  : File::Spec->catfile( '$skill', 'cli', \$verb );
exec \$^X, '-I', File::Spec->catdir('$skill','lib'), \$entry, \@ARGV;
PL
    close $fh;
    chmod 0755, $path or die "chmod: $!";
}

sub gate_says {
    my $here = getcwd();
    chdir $tmp or die "chdir: $!";
    local $ENV{TIRA_HOME} = $root;
    local $ENV{PATH} = $stub . ':' . $ENV{PATH};
    my ( undef, $said ) = run_capturing( 'python3', $tool );
    chdir $here or die "chdir back: $!";
    return $said;
}

my $said = gate_says();

# non-empty is the whole claim: a precondition for the two below, which would
# both pass against a gate that printed nothing at all.
like( $said, qr/\S/, 'the gate has something to say about this board' );

unlike( $said, qr/\Q$report->{ref}\E/,
    'an untouched report is not asked what a ticket somebody is working is asked' );
like( $said, qr/\Q$mine->{ref}\E/,
    'while a card this project is working is asked for all of it' );

# --- and the moment somebody picks the report up ---------------------------
#
# Triage is what turns a report into a ticket, and the board records triage as
# the card leaving the backlog. Until then nobody has decided what it is; after
# that it is this project's work like any other.

$tira->record_move( project => $root, ref => $report->{ref}, column => 'implement' );

like( gate_says(), qr/\Q$report->{ref}\E/,
    'and a report somebody has picked up is a ticket like any other' );

done_testing;

__END__

=head1 NAME

232-a-report-is-not-a-ticket-yet.t - what an inbound report can be asked

=head1 DESCRIPTION

C<tira.dev.found.bug_or_improvement> fills a title, a description, a source and
a reporter, because that is what a reporter knows. The push gate asked such a
card everything it asks a ticket somebody is working, so a gated release waited
on somebody writing up another project's report - three times in one evening,
with more arriving while the first three were being written.

A card carrying a report's source, still in the backlog, is asked what a report
can answer. Leaving the backlog is triage, and after it the card is this
project's work like any other.

=cut
