#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS ();
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
my $pass = Cpanel::JSON::XS->new->decode($out);
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
    # The clock moves between rounds, because escalation now follows tellings
    # rather than passes: the same problem is left alone for a growing quiet
    # period before it is said again, so six rounds at one instant say one
    # thing. Sleeping is what the loop does with the time; here it is where the
    # time passes.
    my @clock = map { sprintf '2026-08-11T%02d:00:00Z', $_ } 10 .. 20;
    my $err = '';
    open my $se, '>', \$err or die $!;
    {
        local *STDERR = $se;
        Tira::CLI::_police_follow( $tira, { project => $root }, $store,
            { rounds => 8, interval => 0, sleeper => sub { $now = shift @clock if @clock } } );
    }
    like( $err, qr/needs your attention/,
        'a violation ignored long enough reaches the terminal from inside the loop' );
    like( $err, qr/hand to (?:the core agent|\w[\w.-]*): d2 tira\./, 'naming who to hand it back to, and the command' );
}

# And from a single pass too, which is the other way he runs it. The loop and
# --once print the terminal message through different lines, and only one of
# them was ever exercised - so a change to the single-pass path would have gone
# out with the suite green and his terminal silent.
{
    my $store = File::Spec->catdir( $tmp, 'escalating-once' );
    my $bare = $tira->create_record( project => $root, type => 'ticket', title => 'Ignored once' );
    $tira->record_move( project => $root, ref => $bare->{ref}, column => 'implement' );

    # Five tellings, spread past each rung of the quiet ladder. Five passes at
    # one instant would be one telling, and nothing would ever be escalated.
    my $said = '';
    for my $hour ( 10 .. 16 ) {
        $now = sprintf '2026-08-12T%02d:00:00Z', $hour;
        my ( undef, undef, $err ) = run( 'police', '--once', '--store', $store );
        $said .= $err;
    }
    like( $said, qr/needs your attention/,
        'a single pass prints escalation to the owner\'s terminal as the loop does' );
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

# --- asking for quiet, and reading what was said --------------------------

# The suspension is the escape hatch, so it is the part most likely to be
# abused - by the agent. Driven here through the dispatcher rather than the
# engine, because the argument guards are where it would be abused from.
{
    my $store = File::Spec->catdir( $tmp, 'quiet' );
    ( $status, my $out, my $err ) = run( 'police.suspend', '--seconds', '60',
        '--reason', 'chasing one failing test', '--store', $store, '-o', 'json' );
    is( $status, 0, 'a suspension can be asked for' );
    like( $err, qr/SUSPENSION/, 'and appears in the owner\'s terminal as it happens' );
    like( $err, qr/chasing one failing test/, 'with the reason given' );

    ( $status, undef, my $no_reason ) =
      run( 'police.suspend', '--seconds', '60', '--store', $store, '-o', 'json' );
    isnt( $status, 0, 'without a reason it is refused' );
    like( $no_reason, qr/reason/, 'saying so' );

    ( $status, undef, my $too_long ) = run( 'police.suspend', '--seconds', '99999',
        '--reason', 'a very long think', '--store', $store, '-o', 'json' );
    isnt( $status, 0, 'and past the ceiling it is refused' );

    ( $status, my $log ) = run( 'police.log', '--store', $store, '-o', 'json' );
    is( $status, 0, 'the enforcement log can be read' );
    like( $log, qr/chasing one failing test/,
        'and carries the reason, written there by police rather than by the agent' );
}

# --- what happened to a card ----------------------------------------------

{
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Watched' );
    $tira->comment_add( project => $root, ref => $card->{ref},
        author => 'michael', text => 'a note about it' );

    ( $status, my $log ) = run( 'worklog.show', '--ref', $card->{ref}, '-o', 'json' );
    is( $status, 0, 'a card\'s work log can be read from the command line' );
    like( $log, qr/commented/, 'and says what happened' );
    like( $log, qr/a note about it/, 'including what was said' );

    ( $status, undef, my $err ) = run( 'worklog.show', '-o', 'json' );
    isnt( $status, 0, 'and it needs to be told which card' );
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
