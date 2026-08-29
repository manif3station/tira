#!/usr/bin/env perl
# A board is backed up if anything has backed it up.
#
# There are two mechanisms and they do not know about each other. `tira.backup`
# commits the board's own .tira directory; `tools/board-backup`, which the push
# gate runs on every push, writes the records out as JSON into a dated directory
# under HOME. board-unbacked reads the first, and only reads the second when the
# first has no answer at all.
#
# So a board the gate has backed up hundreds of times is told it has not been
# backed up since whenever somebody last ran the other command. Measured on this
# project on 2026-08-16: 481 backups from the gate with the newest at 07:20 that
# morning, and the answer the rule was using was 01:03 - six hours earlier, from
# the other mechanism. The rule then tells the reader to run `d2 tira.backup`,
# which is correct advice about what it measures and wrong about the board,
# because the board is backed up more often than the rule would ask for.
#
# The `//` is the whole fault: it means "the git answer, or the directory answer
# if there is no git answer", when the question is when this board was last
# backed up by anything. Two mechanisms, one question, and the answer is the
# later of them.

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
# Tira::CLI::Police holds the police pass, the bridge and the world scan since
# 4.74 (TKT-607). Tira::CLI loads it with require at the point a police verb
# runs, so a test calling into it directly has to ask for it itself.
require Tira::CLI::Police;
# Tira::CLI::Serve holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Serve;
# Tira::CLI::Backup holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Backup;

plan skip_all => 'git is not installed' if !Tira::CLI::Serve::_program_exists('git');

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-08-16T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Backed', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'BKS', epic_prefix => 'BKE', ticket_prefix => 'BKT',
);
$tira->policy_add( project => $root, rule => 'board-unbacked', age => '7d',
    action => 'bridge-reminder' );

# Where the gate writes: a dated directory per backup, named for the moment it
# ran. The rule is pointed at it the way it points at itself.
my $gate_store = File::Spec->catdir( $tmp, 'gate-backups' );

sub unbacked {
    my $world = Tira::CLI::Police::police_world(
        tira => $tira, project => $root, backups => $gate_store );
    my $pass = $tira->police_pass( project => $root,
        store => File::Spec->catdir( $tmp, 'police' ), world => $world );
    return ( [ grep { $_->{rule} eq 'board-unbacked' } @{ $pass->{violations} } ], $world );
}

# --- a board nothing has backed up -------------------------------------------
#
# Asserted first, so what follows is a changed answer rather than a rule with
# nothing to say about this board at all.

{
    my ($found) = unbacked();
    is( scalar @{$found}, 1, 'a board nothing has backed up is told so' );
}

# --- backed up the one way, a long time ago ----------------------------------
#
# tira.backup commits the board. The commit is then dated years back, which is
# what a board looks like when somebody ran that command once and has been
# pushing ever since.
#
# With an identity given on the command line, because the test container has
# none configured and the commit would otherwise refuse - which is how this
# passed here and failed the gate, twice in one morning.

do {
    local $ENV{TIRA_HOME} = $root;
    open my $quiet, '>', File::Spec->devnull or die "devnull: $!";
    my $said = select $quiet;
    Tira::CLI->run( command => 'backup', tira => $tira, argv => [ '-o', 'json' ] );
    select $said;
    close $quiet;
};

{
    my $store = File::Spec->catdir( $root, '.tira' );
    local $ENV{GIT_COMMITTER_DATE} = '2020-01-01T00:00:00+0000';
    local $ENV{GIT_AUTHOR_DATE}    = '2020-01-01T00:00:00+0000';
    system( 'git', '-C', $store, '-c', 'user.name=Tira',
        '-c', 'user.email=tira@localhost',
        'commit', '--allow-empty', '--quiet',
        '-m', 'a backup from a long time ago' ) == 0
      or die 'could not date the board commit';
}

{
    my ( $found, $world ) = unbacked();
    like( $world->{backed_up_at} // '', qr/\A2020/,
        'the one mechanism answers, with the year it ran' );
    is( scalar @{$found}, 1, 'and a board backed up in 2020 is still reported' );
}

# --- and backed up the other way, minutes ago --------------------------------
#
# The gate's backup, which is the one that has actually been running. Nothing
# about the first mechanism changes: its answer is still 2020 and still there.

make_path( File::Spec->catdir( $gate_store, '20260816T085000Z' ) );

{
    my ( $found, $world ) = unbacked();
    is( $world->{backed_up_at}, '2026-08-16T08:50:00Z',
        'the board was last backed up ten minutes ago, by the mechanism that did it' );
    is_deeply( $found, [],
        'so a board the gate backs up is not told it has never been backed up' );
}

# --- proved by narrowing it back to one mechanism ----------------------------
#
# With the directory answer taken away, the question has only the git answer to
# go on - which is what the rule did before this - and the board that was just
# backed up ten minutes ago is reported again. A rule that asks both cannot
# behave this way; a rule that asks one has to.

{
    no warnings 'redefine';
    local *Tira::CLI::Backup::_last_backup = sub { return undef };

    my ( $found, $world ) = unbacked();
    like( $world->{backed_up_at} // '', qr/\A2020/,
        'with one mechanism the answer is the old one again' );
    is( scalar @{$found}, 1,
        'and the board the gate backed up ten minutes ago is reported once more' );
}

# --- and the two are on the same clock ---------------------------------------
#
# The commit answer used to be the local wall clock with the offset thrown away
# and a Z put on the end, which was an hour of slack in an age measured in days
# and nobody's problem. It becomes a problem the moment the two answers are
# compared: this commit happens at 07:55 UTC and reads as 08:55 on a machine an
# hour ahead, which is later than the gate's stamp - so the older backup would
# win and the rule would go back to reporting the newer one as missing.

{
    my $store = File::Spec->catdir( $root, '.tira' );
    local $ENV{GIT_COMMITTER_DATE} = '2026-08-16T08:55:00+0100';
    local $ENV{GIT_AUTHOR_DATE}    = '2026-08-16T08:55:00+0100';
    system( 'git', '-C', $store, '-c', 'user.name=Tira',
        '-c', 'user.email=tira@localhost',
        'commit', '--allow-empty', '--quiet',
        '-m', 'a backup an hour east of here' ) == 0
      or die 'could not date the board commit';

    my ( undef, $world ) = unbacked();
    is( $world->{backed_up_at}, '2026-08-16T08:50:00Z',
        'a commit at 08:55 an hour ahead is 07:55 here, so the 08:50 backup is still the last one' );
}

done_testing;

__END__

=head1 NAME

234-two-ways-to-back-a-board-up.t - one question, both mechanisms

=head1 DESCRIPTION

C<board-unbacked> read the board's own git commit and fell back to the dated
directories only when there was no commit at all. The push gate writes the
dated directories, so a board it had backed up 481 times was told its last
backup was six hours old, and advised to run the command whose answer it was
already using.

The answer is the later of the two, because the question is when this board was
last backed up rather than which mechanism did it.

=cut
