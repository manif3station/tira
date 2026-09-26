#!/usr/bin/env perl
# A no-op backup run still proves the job is alive.
#
# board-unbacked reads backed_up_at, which is the LATER of the board's own git
# commit time and the gate's dated backup directories - neither of which a
# no-op `d2 tira.backup` run can move, because it makes no commit and is not
# the gate. So on a board that is correctly, deliberately idle, running the
# rule's own documented remedy does not clear it: the remedy proves nothing
# happened, when what it needs to prove is that something CHECKED.
#
# MEASURED (TKT-850): a real board sat idle 25h+ by design. `d2 tira.backup`
# reported {"changed":0,...,"at":"<the old commit time>"} - the run's own
# moment never reaches backed_up_at at all.
#
# WRITTEN RED: no separate "last checked" stamp exists yet, so a second,
# later, no-op backup run leaves backed_up_at exactly where the first
# (changed) run left it - which is what this file demonstrates failing.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
require Tira::CLI::Police;
require Tira::CLI::Serve;
require Tira::CLI::Backup;

plan skip_all => 'git is not installed' if !Tira::CLI::Serve::_program_exists('git');

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-09-26T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Idle', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'IDS', epic_prefix => 'IDE', ticket_prefix => 'IDT',
);
$tira->policy_add( project => $root, rule => 'board-unbacked', age => '1h',
    action => 'bridge-reminder' );

sub run_backup {
    ( my $git_date = $now ) =~ s/Z\z/+0000/;
    local $ENV{TIRA_HOME} = $root;
    local $ENV{GIT_COMMITTER_DATE} = $git_date;
    local $ENV{GIT_AUTHOR_DATE}    = $git_date;
    my $printed = '';
    open my $captured, '>', \$printed or die $!;
    my $said = select $captured;
    Tira::CLI->run( command => 'backup', tira => $tira, argv => [ '-o', 'json' ] );
    select $said;
    close $captured;
    return Tira::json_object()->decode($printed);
}

sub unbacked {
    my $world = Tira::CLI::Police::police_world( tira => $tira, project => $root );
    my $pass = $tira->police_pass( project => $root,
        store => File::Spec->catdir( $tmp, 'police' ), world => $world );
    return ( [ grep { $_->{rule} eq 'board-unbacked' } @{ $pass->{violations} } ], $world );
}

# --- first backup: a real commit, board created and captured ----------------

run_backup();

{
    my ( $found, $world ) = unbacked();
    is( $world->{backed_up_at}, $now, 'the first backup, a real commit, sets backed_up_at to its own moment' );
    is_deeply( $found, [], 'and the board just backed up is not reported' );
}

# --- time passes PAST the policy window since the first commit, board stays
# --- idle throughout - a second `d2 tira.backup` run is a genuine no-op ----

$now = '2026-09-26T10:30:00Z';
my $second = run_backup();
is( $second->{changed}, 0, 'the second run is a genuine no-op - nothing had changed' );

# --- now past the age window measured from the FIRST commit (2h, past the 1h
# --- age), but still within it measured from the SECOND (no-op) run (30m) --
#
# This is the case the rule cannot answer without evidence the no-op run ever
# happened: two hours since the last COMMIT, but only thirty minutes since the
# last time anybody actually CHECKED.

$now = '2026-09-26T11:00:00Z';

{
    my ( $found, $world ) = unbacked();
    is( $world->{backed_up_at}, '2026-09-26T10:30:00Z',
        "backed_up_at reflects the second run's own moment, not just the first commit's" );
    is_deeply( $found, [],
        'a board checked 30 minutes ago is not told it has never been backed up, even though its last COMMIT is 2 hours old' );
}

done_testing;

__END__

=head1 NAME

850-a-check-that-proves-nothing-changed.t - a no-op backup is still evidence the job is alive

=head1 DESCRIPTION

C<board-unbacked> reads C<backed_up_at>, computed from the board's own git
commit time and the gate's dated backup directories - the later of the two.
Neither moves when C<d2 tira.backup> runs and finds nothing to commit, so the
rule's own documented remedy cannot ever clear it on a board that is
correctly, deliberately idle: the remedy proves nothing changed, not that
anybody checked.

C<backed_up_at> needs a third source: the moment C<tira.backup> was last RUN,
whether or not it found anything to commit.

=cut
