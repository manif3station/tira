#!/usr/bin/env perl
# board-unbacked reads what Tira writes, and names the command that clears it.
#
# The rule asked a directory under the home folder for the last backup, and only
# tools/board-backup - inside Tira's own repository, run by its push gate - ever
# wrote there. So the rule worked on exactly one board on earth. Everywhere else
# it fired for ever, and the line it printed ended in "fix: d2 tira.policy.list",
# which lists policies and backs nothing up. The loudest tone the rule can reach
# still gave an instruction that does not help.
#
# He read it off his own bridge and asked what backup. There wasn't one.
#
# Two changes. The rule asks the board's own repository, which is what
# tira.backup writes and what any board can have - falling back to the old place,
# so a board backed up by the old tool is not suddenly told it never was. And a
# rule about the board itself names the command that answers it.
#
# The fix line was built in two places by the same expression, which is the shape
# this project has now found three times: two program lookups, two message
# paths, and this. It is one expression now.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

plan skip_all => 'git is not installed here' if !Tira::CLI::_program_exists('git');

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-13T12:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Kept', dir => $root, members => ['michael'],
    columns => ['backlog, doing, done'],
    sow_prefix => 'KPS', epic_prefix => 'KPE', ticket_prefix => 'KPT',
);
$tira->create_record( project => $root, type => 'ticket', title => 'Worth keeping' );
$tira->policy_add( project => $root, rule => 'board-unbacked', age => '1m',
    action => 'bridge-reminder' );

my $store = File::Spec->catdir( $tmp, 'police' );
my $nowhere = File::Spec->catdir( $tmp, 'no-such-backups' );

sub unbacked {
    my $pass = $tira->police_pass(
        project => $root, store => $store,
        world => Tira::CLI::_police_world( tira => $tira, project => $root, backups => $nowhere ),
    );
    my ($found) = grep { $_->{rule} eq 'board-unbacked' } @{ $pass->{violations} };
    return $found;
}

sub run {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => shift(@argv), tira => $tira,
            argv => [ @argv ] ) };
    };
    return $status;
}

# --- it fires, as it should ---------------------------------------------------

my $before = unbacked();
ok( $before, 'a board that has never been backed up is reported' );
like( $before->{detail}, qr/never been backed up/, 'saying so plainly' );

# --- and it goes quiet once the board is backed up ----------------------------
#
# The whole point. Until now this was true on one repository and false on every
# other board using this skill.

is( run( 'backup' ), 0, 'the board is backed up with the command that ships' );

# The commit is stamped by git with the real time, and this board's clock is
# mocked - so the clock is moved to just after the backup rather than to a date
# chosen in advance. A fixture that ignores that would prove only that an hour
# is longer than a minute.
my $backed_up = Tira::CLI::_last_backup_commit( Tira::CLI::_backup_store($root) );
like( $backed_up, qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/,
    'the backup is readable as a time, from the repository rather than a directory of stamps' );

$now = $backed_up;
ok( !unbacked(), 'and the rule goes quiet, on a board that is not Tira\'s own' );

# --- and speaks again when the backup goes stale ------------------------------
#
# Going quiet for ever after one backup would be worse than never firing: it
# would say a board was safe on the strength of something done in March.

# Two hours later by arithmetic on the time, not on the digits. Adding two to
# the hour field and taking it modulo twenty-four moves 23:07 to 01:07 the same
# morning - twenty-two hours backwards - so this passed all day and failed in
# the push gate at ten at night. A test that is right for twenty-two hours out
# of twenty-four is a test passing for the wrong reason.
$now = Tira::_iso_from_epoch(
    Tira::_epoch_of_datetime( $backed_up, 'Backup' ) + 2 * 60 * 60 );
ok( unbacked(), 'and speaks again once that backup is older than the rule allows' );

# --- the line names what answers it -------------------------------------------

my $line = Tira::_violation_fix( { rule => 'board-unbacked', ref => '' } );
is( $line, 'd2 tira.backup', 'a rule about the board names the command that clears it' );

# --- without changing what every other rule says ------------------------------

is( Tira::_violation_fix( { rule => 'wip-limit', ref => '' } ), 'd2 tira.policy.list',
    'a rule about the board with nothing better to say still says what it said' );
is( Tira::_violation_fix( { rule => 'card-full-details', ref => 'KPT-001' } ),
    'd2 tira.ticket.show --ref KPT-001', 'a rule about a card still points at the card' );
is( Tira::_violation_fix( { rule => 'orphan-card', ref => 'SOW-001' } ),
    'd2 tira.sow.show --ref SOW-001', 'and a statement of work at the statement of work' );
is( Tira::_violation_fix( { rule => 'orphan-card', ref => 'EPC-001' } ),
    'd2 tira.epic.show --ref EPC-001', 'and an epic at the epic' );

# --- and it is one expression, not two that agree today -----------------------
#
# The bridge line and the owner's terminal both end in a fix. They were built by
# the same expression written out twice, which is how the program lookup and the
# message substitution both drifted before this.

my $source = do {
    open my $handle, '<', 'lib/Tira.pm' or die $!;
    local $/;
    <$handle>;
};
my $count = () = $source =~ /tira\.ticket\.show --ref \$ref/g;
is( $count, 1, 'the fix line is worked out in one place, not written out twice' );

done_testing;

__END__

=head1 NAME

126-the-rule-names-what-answers-it.t - board-unbacked reads what Tira writes

=head1 DESCRIPTION

C<board-unbacked> read a directory that only a development tool inside Tira's
own repository ever wrote to, so the rule was satisfiable on exactly one board
and permanently unsatisfiable everywhere else - and the line it printed ended in
a command that lists policies rather than one that backs anything up.

It now asks the board's own repository, falling back to the old place so a board
backed up by the old tool is not suddenly told it never was, and names
C<tira.backup> as the fix. The fix line is built in one place rather than by the
same expression written out twice.

=cut
