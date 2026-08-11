#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-11T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Policed', dir => $root, members => ['michael'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'PCS', epic_prefix => 'PCE', ticket_prefix => 'PCT',
);

my $run_roles;

sub run {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run(
            command => shift(@argv), tira => $tira,
            argv => [ '--project', $root, @argv ],
        );
    };
    return ( $status, $out, $err );
}

$run_roles = sub { return run( 'column.roles', @_ ) };

# --- police with nothing to follow ----------------------------------------

# The owner runs this and nobody has set any policies. It must not sit there
# pretending to guard something: it says so, exits, and gives him the exact
# thing to paste to the agent.
my ( $status, $out, $err ) = run( 'police', '--once' );
isnt( $status, 0, 'police exits non-zero when it has nothing to follow' );
like( "$out$err", qr/tira\.policy/,
    'and names the command that would give it something to follow' );
like( "$out$err", qr/no polic/i, 'saying plainly that none are set' );

# --- police watching ------------------------------------------------------

$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Bare' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );

( $status, $out ) = run( 'police', '--once', '-o', 'json' );
is( $status, 0, 'with a policy set, one pass succeeds' );
my $pass = JSON::PP->new->decode($out);
ok( $pass->{watching}, 'and says it is watching' );
is( scalar @{ $pass->{violations} }, 1, 'reporting what it found' );

# --- and the agent can read it off the bridge -----------------------------

( $status, my $bridge ) = run( 'policy.bridge', '--once' );
is( $status, 0, 'the bridge reads without waiting when asked for one pass' );
like( $bridge, qr/\Q$card->{ref}\E/, 'and shows what police said about the card' );
like( $bridge, qr/fix:/, 'including what to do about it' );

# Found by running the command rather than by a test: the dispatch's return
# value was being formatted as output, so an agent tailing an empty bridge saw
# a bare 0 where it expected violations - and a 0 that means nothing looks
# exactly like a 0 that means all is well.
{
    my $empty = File::Spec->catdir( $tmp, 'nothing-said' );
    ( $status, my $silence ) = run( 'policy.bridge', '--once', '--store', $empty );
    is( $status, 0, 'a bridge with nothing on it succeeds' );
    unlike( $silence, qr/\A0\s*\z/,
        'and says nothing, rather than printing a number that could be read as a violation' );
}

# --- the board is untouched by any of it ----------------------------------

require File::Find;
require Digest::SHA;
sub fingerprint {
    my @found;
    File::Find::find(
        { no_chdir => 1, wanted => sub {
            return if !-f $File::Find::name;
            open my $fh, '<:raw', $File::Find::name or return;
            my $bytes = do { local $/; <$fh> };
            close $fh;
            push @found, "$File::Find::name:" . Digest::SHA::sha256_hex($bytes);
        } }, File::Spec->catdir( $root, '.tira' ) );
    return [ sort @found ];
}
my $before = fingerprint();
run( 'police', '--once', '-o', 'json' ) for 1 .. 3;
run( 'policy.bridge', '--once' );
is_deeply( fingerprint(), $before,
    'running police and the bridge changes not one byte of the board' );

# --- the loops that are meant to run for ever -----------------------------

# A loop with no end cannot be called by anything, including a test, so both
# take a number of rounds and a way of waiting. Left alone they run for ever,
# which is what the owner and the agent both want; bounded, they can be proved.
{
    ( $status, my $watched ) = run( 'police', '--rounds', '2', '--interval', '0' );
    is( $status, 0, 'police survives more than one round' );

    my $store = File::Spec->catdir( $tmp, 'looping' );
    $tira->bridge_write( store => $store, violations => [ {
        id => 'VIO-0001', rule => 'card-stalled', ref => 'PCT-001',
        detail => 'said before the bridge started', action => 'bridge-reminder',
        tone => 'note', seen => 1 } ] );
    ( $status, my $followed ) = run( 'policy.bridge', '--rounds', '1', '--interval', '0', '--store', $store );
    is( $status, 0, 'the bridge survives a round of following' );
    like( $followed, qr/said before the bridge started/,
        'and shows what was already outstanding when it arrived, not only what comes next' );
}

# A bridge that is following must show lines that arrive WHILE it is following,
# not only the ones that were there when it started. That is the whole point of
# following, and it is a different code path from the backlog.
{
    my $live = File::Spec->catdir( $tmp, 'arriving' );
    $tira->bridge_write( store => $live, violations => [ {
        id => 'VIO-0001', ref => 'PCT-001', detail => 'said before',
        action => 'bridge-reminder', tone => 'note', seen => 1 } ] );

    my $arriving = 0;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI::_bridge_follow( $tira, $live, rounds => 2, sleeper => sub {
            return if $arriving++;
            $tira->bridge_write( store => $live, violations => [ {
                id => 'VIO-0002', ref => 'PCT-002', detail => 'said while listening',
                action => 'bridge-reminder', tone => 'warning', seen => 2 } ] );
        } );
    }
    like( $out, qr/said while listening/,
        'a line written while the bridge is following reaches the agent' );
    unlike( $out, qr/said before/,
        'and one it had already shown is not repeated at it' );
}

# Police must survive a board it cannot read, and say so, rather than stopping.
# A supervisor that gives up on the first bad read is a supervisor that is not
# there the one time it matters.
{
    no warnings 'redefine';
    local *Tira::police_pass = sub { die "Board is locked\n" };
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $survived = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI::_police_follow( $tira, { project => $root },
            File::Spec->catdir( $tmp, 'unreadable' ),
            { rounds => 2, interval => 0 } );
    };
    is( $survived->{rounds}, 2, 'police keeps going after a board it could not read' );
    like( $err, qr/could not read the board/, 'saying so each time rather than silently' );
}

# It says why it is going before it goes. A supervisor that dies quietly is
# worse than none, because its silence reads as everything being fine. The
# words are split out from the signal handler so they can be checked by being
# called, rather than only by killing the process.
{
    my $err = '';
    open my $se, '>', \$err or die $!;
    {
        local *STDERR = $se;
        Tira::CLI::_police_goodbye( $tira, 'INT' );
    }
    like( $err, qr/no longer watching/i, 'the farewell says nothing is watching now' );
    like( $err, qr/signal INT/, 'and why it stopped' );
}

# And the handler that says it really is wired to the signals, rather than
# being a function nothing ever calls. How it leaves is injectable so this can
# be proved without killing the test.
{
    my ( $left, $err ) = ( 0, '' );
    open my $se, '>', \$err or die $!;
    {
        local *STDERR = $se;
        Tira::CLI::_police_follow( $tira, { project => $root },
            File::Spec->catdir( $tmp, 'signalled' ),
            { rounds => 1, interval => 0, leave => sub { $left++ } } );
        $SIG{$_}->($_) for qw(INT TERM HUP);
    }
    is( $left, 3, 'every signal it handles goes through the same leaving' );
    like( $err, qr/signal TERM/, 'and each says which signal it was' );
}

# And by default it really does stop, rather than saying it will and carrying
# on. That cannot be proved in this process without ending it, so it is proved
# in a child: police must actually go when it is asked to.
SKIP: {
    skip 'fork is not available here', 2 if !eval { my $pid = fork; defined $pid or die; $pid == 0 and exit 0; waitpid $pid, 0; 1 };

    my $child = fork;
    die 'cannot fork' if !defined $child;
    if ( !$child ) {
        close STDERR;
        Tira::CLI::_police_follow( $tira, { project => $root },
            File::Spec->catdir( $tmp, 'really-leaving' ), { rounds => 1, interval => 0 } );
        $SIG{INT}->('INT');
        exit 99;    # only reached if the handler did not leave
    }
    waitpid $child, 0;
    my $status = $? >> 8;
    is( $status, 0, 'the default handler really does end the process' );
    isnt( $status, 99, 'rather than saying it is going and carrying on' );
}

# Escalation reaching the owner's terminal from inside the loop, rather than
# only from a single pass. This is the path he actually sees.
{
    my $store = File::Spec->catdir( $tmp, 'escalating-loop' );
    my $bare = $tira->create_record( project => $root, type => 'ticket', title => 'Ignored' );
    $tira->record_move( project => $root, ref => $bare->{ref}, column => 'implement' );
    my $err = '';
    open my $se, '>', \$err or die $!;
    {
        local *STDERR = $se;
        Tira::CLI::_police_follow( $tira, { project => $root }, $store,
            { rounds => 6, interval => 0 } );
    }
    like( $err, qr/needs your attention/,
        'a violation ignored long enough reaches the terminal from inside the loop' );
    like( $err, qr/paste to the agent/, 'with something he can hand straight back' );
}

# --- saying which column is which ------------------------------------------

# A rule tied to a column name says nothing the moment somebody renames the
# column. Roles are how a policy survives that, so the verb that declares them
# belongs with the rest of the surface.
{
    ( $status, my $set ) = $run_roles->( '--type', 'ticket',
        '--role', 'in-progress=implement', '--role', 'done=done', '-o', 'json' );
    is( $status, 0, 'roles can be declared' );
    like( $set, qr/implement/, 'and say which column plays each one' );

    ( $status, my $read ) = $run_roles->( '--type', 'ticket', '-o', 'json' );
    like( $read, qr/in-progress/, 'and are read back with no arguments' );

    ( $status, undef, my $err ) = $run_roles->( '--type', 'ticket', '--role', 'nonsense', '-o', 'json' );
    isnt( $status, 0, 'a role written the wrong way round is refused' );
    like( $err, qr/name=column/, 'with the shape it wanted' );
}

# --- the help an agent needs ----------------------------------------------

# The agent needs one command to learn the whole surface. Reading source to
# find out what rules exist is a surface nobody will use.
( $status, my $help ) = run('policies');
is( $status, 0, 'tira.policies answers with no arguments at all' );
like( $help, qr/card-stalled/, 'listing the rules' );
like( $help, qr/bridge-reminder/, 'and the actions' );
like( $help, qr/tira\.policy\.add/, 'and how to declare one' );

# The command must print the real document, not a summary of it. The path was
# wrong when this was first wired - it looked one directory too shallow - and
# the fallback answered instead, which looked entirely reasonable and was not
# what an agent needed.
like( $help, qr/not a prescription/i,
    'and prints the document itself, including the warning not to copy it wholesale' );
like( $help, qr/raise a\s+ticket and ask/i,
    'and the instruction to ask rather than guess' );
like( $help, qr/worse than no policy/i,
    'and that a policy without the bridge running looks like cover' );

# An installation whose documents are missing must still be able to say what
# exists, rather than answering nothing at all - so the fallback is exercised
# rather than left as code that only runs somewhere nobody is looking.
{
    my $bare = Tira::CLI::_policy_help(
        document => File::Spec->catfile( $tmp, 'no-such-document.md' ) );
    like( $bare, qr/card-stalled/, 'with no document, the rules are still listed' );
    like( $bare, qr/tira\.police/, 'and both commands are still named' );
    unlike( $bare, qr/not a prescription/,
        'while making no claim to be the document it could not find' );
}

my ( $flag_status, $flag_help ) = run( 'policies', '--help' );
is( $flag_help, $help, 'and answers the same way with --help, so neither form is a dead end' );

done_testing;

__END__

=head1 NAME

84-police-commands.t - the two commands, and the help that explains them

=head1 DESCRIPTION

The owner runs one command and needs no other: C<d2 tira.police>. The agent
runs one command and needs no other: C<d2 tira.policy.bridge>. This covers
both at the dispatcher, so the argument parsing and the output contract are
proved rather than assumed.

Police with nothing to follow is the case that matters most. It exits, says so,
and hands the owner the exact thing to paste to the agent - because a watcher
that runs while guarding nothing is worse than no watcher at all, its presence
reading as cover.

Both commands are run three times over and the board is fingerprinted before
and after, because read-only is the promise the whole design rests on and it is
worth checking at the command layer as well as the engine.

C<tira.policies> answers with no arguments and with C<--help>, since an agent
that has to read source to find out what rules exist will not use the surface
at all.

=cut
