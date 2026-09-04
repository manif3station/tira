#!/usr/bin/env perl
# Serving a board and hearing from it, from one terminal.
#
# TKT-897, filed by him: "add a new --with-police argument that will run the
# police and the starman at the same terminal. So the user doesn't need to run 2
# terminals. All in 1 go."
#
# THIS FILE COVERS THE FIRST HALF ONLY, and the split is not a convenience. His
# second sentence - "the police will be always the winner in this running with
# browser dashboard. if other try to run tira.police will be the losser and
# exit" - asks for the reverse of his OWN earlier ruling on TKT-486, quoted in
# the code that implements it: "Whoever the last run it is the winner and the
# loser process will be killed."
#
# THE BOARD DOES THE SECOND ONE TODAY. Read rather than assumed:
# police_claim_singleton kills whatever holds the claim, takes it, and prints
# "killed a still-running daemon - only the newest watches now". So the
# precedence this card asks for is a change to a rule he made, not a default
# nobody chose, and it is Q-117 rather than something to infer. Nothing here
# asserts it.
#
# WHAT IS ASSERTED is the plumbing he asked for in his first sentence, which
# nothing about the question blocks: the flag exists, it is refused where it
# cannot mean anything, and it is written down.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite;

# --- the parser knows the flag ----------------------------------------------
#
# Taken from the option specification itself rather than from a list here, the
# way t/70 reads it: a flag this test names and the parser does not is a flag
# nobody can type.

my $cli = Suite::cli_source();

# non-empty is the whole claim: every assertion below greps this text, and a
# walk that returned nothing would report the flag as missing rather than absent.
like( $cli, qr/\S/, 'the command surface was walked to look for the flag' );

like( $cli, qr/'with-police'/,
    'THE PARSER DECLARES --with-police, so it can be typed at all. His first '
      . 'sentence is the whole of this assertion: one command for the board and '
      . 'the bridge, instead of two terminals' );

# --- and refuses it where it cannot mean anything ---------------------------
#
# --show-logs is the precedent and the comment beside it is the reason: "a flag
# that parses and does nothing reads as confirmation, which is how --field was
# stored and dropped by every command that did not read it". Police alongside a
# JSON dump is the same shape - there is no terminal being shared, so the flag
# would be accepted and ignored.

like( $cli, qr/--with-police needs -o browser|with_police.*?browser|browser.*?with_police/s,
    'and it is REFUSED outside -o browser rather than accepted and ignored - '
      . 'the fault --show-logs is guarded against by name, since a flag that '
      . 'parses and does nothing reads as confirmation' );

# --- one signal path, so nothing is left holding a claim --------------------
#
# The card's second acceptance criterion. A police pass that outlives the server
# leaves a singleton claim pointing at a pid that is gone, and the next claimant
# has to reason past it. police_release_singleton exists for exactly that and
# has to be reached on this path too.

like( $cli, qr/with_police/,
    'the flag reaches the serving path rather than stopping at the parser - a '
      . 'value read once and never used is the accepted-and-ignored fault again' );

# --- written down where the command is written down -------------------------

{
    my %doc;
    for my $name ( 'SKILLS.md', File::Spec->catfile( 'docs', 'commands.md' ) ) {
        open my $fh, '<:encoding(UTF-8)', $name or die "$name: $!";
        local $/;
        $doc{$name} = <$fh>;
    }

    # non-empty is the whole claim, as above.
    for my $name ( sort keys %doc ) {
        like( $doc{$name}, qr/\S/, "$name was read to look for the flag" );
    }

    for my $name ( sort keys %doc ) {
        like( $doc{$name}, qr/--with-police/,
            "$name names --with-police, so somebody can find it without reading "
              . 'the option table in the source' );
    }
}

# --- the precedence, now that he has settled it -----------------------------
#
# Q-117, answered 2026-09-04T01:57:51: "The dashboard is a special case - while
# it holds police, a later tira.police says so and exits 0. TKT-486 still
# applies everywhere else."
#
# So BOTH rules stand, in different places, and the tests have to hold both -
# the new one is worth nothing if it quietly weakens the old one.

use File::Temp qw(tempdir);
use Tira::CLI::Police;

# TKT-486 UNCHANGED: two ordinary daemons, and the newest still kills the first.
{
    my $store = tempdir( CLEANUP => 1 );
    my @killed;

    Tira::CLI::Police::police_claim_singleton( $store,
        pid => 4001, alive => sub { 0 }, kill => sub { push @killed, $_[0] } );

    my $second = Tira::CLI::Police::police_claim_singleton( $store,
        pid => 4002, alive => sub { 1 }, kill => sub { push @killed, $_[0] } );

    is_deeply( \@killed, [4001],
        'TKT-486 IS UNTOUCHED - an ordinary police still kills the ordinary one '
          . 'that held the claim. He said so in the same sentence that made the '
          . 'dashboard an exception, and an exception that quietly replaced the '
          . 'rule would not be what he asked for' );

    is( ( $second || {} )->{claimed}, 4002,
        'and the newest holds it afterwards' );

    ok( !( $second || {} )->{yield},
        'nothing yields here - yielding is the dashboard case only' );
}

# THE DASHBOARD IS THE EXCEPTION: a later police finds it, stands down, says so.
{
    my $store = tempdir( CLEANUP => 1 );
    my @killed;

    Tira::CLI::Police::police_claim_singleton( $store,
        pid => 5001, holder => 'dashboard',
        alive => sub { 0 }, kill => sub { push @killed, $_[0] } );

    my $later = Tira::CLI::Police::police_claim_singleton( $store,
        pid => 5002, alive => sub { 1 }, kill => sub { push @killed, $_[0] } );

    is_deeply( \@killed, [],
        'A LATER POLICE DOES NOT KILL THE DASHBOARD. This is the whole of his '
          . 'answer: while the dashboard holds police, the later one is the one '
          . 'that steps aside' );

    ok( ( $later || {} )->{yield},
        'it yields instead, and says so in what it returns rather than leaving '
          . 'the caller to infer it from an absence' );

    is( ( $later || {} )->{holder}, 'dashboard',
        'naming WHO holds it, so the message the loser prints can say something '
          . 'true rather than "something else is running"' );

    is( ( $later || {} )->{holding_pid}, 5001,
        'and which process, so somebody can go and look at it' );
}

# AND THE CLAIM IS NOT STOLEN WHILE YIELDING. A yielding claimant that wrote its
# own pid into the file would leave the dashboard still running while the file
# pointed at a process that had just exited - the board saying something untrue
# about a live process, which is what this epic exists to stop.
{
    my $store = tempdir( CLEANUP => 1 );

    Tira::CLI::Police::police_claim_singleton( $store,
        pid => 6001, holder => 'dashboard', alive => sub { 0 }, kill => sub { } );

    Tira::CLI::Police::police_claim_singleton( $store,
        pid => 6002, alive => sub { 1 }, kill => sub { } );

    my $path = Tira::CLI::Police::police_singleton_path($store);
    open my $fh, '<', $path or die "$path: $!";
    my $held = do { local $/; <$fh> };
    close $fh;

    like( $held, qr/6001/,
        'THE FILE STILL NAMES THE DASHBOARD after a later police has yielded - '
          . 'a loser that wrote its own pid on the way out would leave the '
          . 'record pointing at a process that is about to exit' );
}

# A DEAD DASHBOARD IS NOT A REASON TO STAND DOWN. The claim outliving the process
# is the ordinary case after a crash, and treating it as a live holder would make
# one unclean exit block police for ever.
{
    my $store = tempdir( CLEANUP => 1 );

    Tira::CLI::Police::police_claim_singleton( $store,
        pid => 7001, holder => 'dashboard', alive => sub { 0 }, kill => sub { } );

    my $later = Tira::CLI::Police::police_claim_singleton( $store,
        pid => 7002, alive => sub { 0 }, kill => sub { } );

    ok( !( $later || {} )->{yield},
        'a claim left behind by a dashboard that is GONE does not make the next '
          . 'police stand down - otherwise one unclean exit would block police '
          . 'until somebody deleted a file by hand' );

    is( ( $later || {} )->{claimed}, 7002, 'it takes the claim instead' );
}

# --- and the loser SAYS SO, through the real watch loop ---------------------
#
# His answer again: "a later tira.police says so and exits 0". Both halves are
# asserted, because either alone is the wrong outcome: a process that stands
# down silently is the shape this epic removes, and one that stands down with a
# non-zero status makes every wrapper treat a working board as a broken one.
#
# Exercised through police_follow rather than by reading its source, for the
# reason that has caught this card's sibling twice: a claim that a branch exists
# is not a claim that it runs.

{
    my $tmp   = tempdir( CLEANUP => 1 );
    my $root  = File::Spec->catdir( $tmp, 'board' );
    my $store = File::Spec->catdir( $tmp, 'police' );

    my $tira = Tira->new;
    $tira->project_new(
        name => 'Yield', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'YLS', epic_prefix => 'YLE', ticket_prefix => 'YLT',
    );

    # The dashboard is in possession.
    Tira::CLI::Police::police_claim_singleton( $store,
        pid => 8001, holder => 'dashboard', alive => sub { 0 }, kill => sub { } );

    my @killed;
    my $said = '';
    my $status;
    {
        # The message is the assertion, so it is captured rather than printed
        # into the harness output where nothing would check it.
        local *STDERR;
        open *STDERR, '>', \$said or die "cannot capture stderr: $!";
        $status = Tira::CLI::Police::police_follow(
            $tira, { project => $root }, $store,
            {   rounds    => 1,
                sleeper   => sub { },
                singleton => {
                    pid   => 8002,
                    alive => sub { 1 },
                    kill  => sub { push @killed, $_[0] },
                },
            } );
    }

    is( $status, 0,
        'THE LOSER EXITS 0 - standing aside is the correct outcome, not a '
          . 'failure, and a non-zero status would make every wrapper read a '
          . 'working board as a broken one' );

    is_deeply( \@killed, [],
        'and it killed nothing on its way out' );

    like( $said, qr/dashboard/i,
        'IT SAYS WHY. A process that vanishes with no message is the exact shape '
          . 'EPC-014 exists to remove, and this one is vanishing on purpose - '
          . 'which is the case most likely to be mistaken for a crash' );

    like( $said, qr/8001/,
        'naming the process that holds the watch, because "something else is '
          . 'running" is the kind of message that sends somebody hunting' );
}

# --- the pass is started beside the board, and dies with it -----------------
#
# The card's second acceptance criterion, and it was implemented with nothing
# exercising it - found by asking what was still missing rather than by the
# suite, which was green. A police child outliving the server would hold the
# singleton claim while nothing served the board, so the next tira.police would
# stand down in favour of a dashboard that is gone.
#
# Driven through the real dispatcher with the seams injected, the way t/101 and
# t/124 already drive the serving path. The seams exist because starting police
# FORKS and the watch loop never returns - a test without them would leave a
# police daemon running inside the harness.

{
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'Beside', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'BSS', epic_prefix => 'BSE', ticket_prefix => 'BST',
    );

    my ( @started, @stopped, $served );
    my $run = sub {
        my (@extra) = @_;
        @started = @stopped = ();
        $served  = 0;
        my ( $out, $err ) = ( '', '' );
        open my $so, '>', \$out or die $!;
        open my $se, '>', \$err or die $!;
        {
            local *STDOUT = $so;
            local *STDERR = $se;
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run(
                command        => 'dashboard.ticket',
                tira           => $tira,
                argv           => [ '-o', 'browser', @extra ],
                browser_server => sub { $served = 1; return 1 },
                police_starter => sub { push @started, {@_}; return 4242 },
                police_stopper => sub { push @stopped, $_[0]; return 1 },
            );
        }
        return $err;
    };

    # WITH the flag.
    $run->('--with-police');

    is( scalar @started, 1,
        'ONE COMMAND STARTS BOTH - the police pass is started beside the served '
          . 'board, which is the whole of his first sentence' );

    ok( $served, 'and the board is still served - police is beside it, not instead of it' );

    is_deeply( \@stopped, [4242],
        'AND STOPPING THE COMMAND STOPS BOTH. The pass it started is the pass it '
          . 'stops, by the pid the starter returned - a child left running would '
          . 'hold the singleton claim while nothing served the board, so the next '
          . 'tira.police would stand down for a dashboard that is gone' );

    is( ( $started[0] || {} )->{project}, $root,
        'the pass is pointed at the board being served rather than at whatever a '
          . 'child with no context would resolve for itself' );

    # WITHOUT the flag: nothing is started and nothing is stopped.
    $run->();

    is_deeply( \@started, [],
        'and without --with-police nothing is started - the flag is the whole of '
          . 'the difference, so somebody who did not ask for police does not get '
          . 'a second process' );

    is_deeply( \@stopped, [], 'nor stopped, since there was nothing to stop' );
}

# --- a fork that fails is said, not swallowed -------------------------------
#
# The board is still served. Losing the bridge is worse with no explanation than
# with one, and it is not a reason to refuse somebody the board they asked for.

{
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'Failed', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'FLS', epic_prefix => 'FLE', ticket_prefix => 'FLT',
    );

    my ( $served, @stopped );
    my ( $said, $out ) = ( '', '' );
    {
        open my $so, '>', \$out  or die $!;
        open my $se, '>', \$said or die $!;
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run(
            command        => 'dashboard.ticket',
            tira           => $tira,
            argv           => [ '-o', 'browser', '--with-police' ],
            browser_server => sub { $served = 1; return 1 },
            police_starter => sub { return undef },
            police_stopper => sub { push @stopped, $_[0]; return 1 },
        );
    }

    ok( $served,
        'a police pass that could not be started does not cost somebody their '
          . 'board - the flag asked for both, and one of them is still possible' );

    like( $said, qr/police/i,
        'and it SAYS the bridge is missing rather than serving a board that '
          . 'quietly is not watched, which reads exactly like one that is' );

    is_deeply( \@stopped, [],
        'nothing is stopped, because nothing was started - a stopper called with '
          . 'an undefined pid is how a signal ends up somewhere nobody meant' );
}

# --- and the real starter and stopper, not only the seams -------------------
#
# The seams above let the dispatcher be tested without forking. That is exactly
# how a default implementation ends up with no test at all - the thing every
# caller uses becomes the thing nothing exercises. Found by asking which lines
# could possibly be covered, which is the same check that caught two providers
# on TKT-892 that were counted and never called.
#
# So these call the real ones, with a real child.

{
    my $tmp   = tempdir( CLEANUP => 1 );
    my $root  = File::Spec->catdir( $tmp, 'board' );
    my $store = File::Spec->catdir( $tmp, 'police' );

    my $tira = Tira->new;
    $tira->project_new(
        name => 'Real', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'RLS', epic_prefix => 'RLE', ticket_prefix => 'RLT',
    );

    require Tira::CLI::Serve;

    my $child = Tira::CLI::Serve::_start_police_beside_board(
        tira => $tira, project => $root, store => $store );

    ok( $child && $child > 0,
        'THE REAL STARTER FORKS AND ANSWERS WITH THE CHILD - the parent gets a '
          . 'pid back rather than falling into the watch loop itself' );

    ok( kill( 0, $child ), 'and the process it names is really there' );

    my $stopped = Tira::CLI::Serve::_stop_police_beside_board($child);
    ok( $stopped, 'the real stopper reports it stopped something' );

    ok( !kill( 0, $child ),
        'AND THE CHILD IS ACTUALLY GONE, reaped rather than left for whenever '
          . 'the system happens to collect it - the claim has to be released '
          . 'before the serving command returns, not eventually' );
}

# A FORK THAT FAILS ANSWERS undef, which is what the dispatcher reads to decide
# whether to say the bridge is missing. Reached by handing it a fork that fails,
# because there is no other honest way to reach it.
{
    require Tira::CLI::Serve;

    my $none = Tira::CLI::Serve::_start_police_beside_board(
        tira => undef, project => undef, store => undef, forker => sub { return undef } );

    ok( !defined $none,
        'a fork that fails answers undef rather than a pid nobody can signal' );

    is( Tira::CLI::Serve::_stop_police_beside_board(undef), 0,
        'and stopping nothing does nothing - a stopper handed an undefined pid '
          . 'is how a signal ends up somewhere nobody meant' );
}

# --- a holder is one of two things, not free text ---------------------------
#
# From an adversarial review of the claim function. The first version preserved
# the bare-pid write only for the exact string 'police', so a caller being
# slightly wrong changed the on-disk format that three other tests read - and a
# third token in the file made an ordinary claim read as a dashboard, which is
# the failure that matters, because the dashboard is the one holder nobody may
# kill.

{
    my $store = tempdir( CLEANUP => 1 );
    my $path  = Tira::CLI::Police::police_singleton_path($store);

    my $read = sub {
        open my $fh, '<', $path or die "$path: $!";
        local $/;
        return scalar <$fh>;
    };

    for my $odd ( '', 'Police', 'nonsense' ) {
        Tira::CLI::Police::police_claim_singleton( $store,
            pid => 9001, holder => $odd, alive => sub { 0 }, kill => sub { } );
        is( $read->(), '9001',
            "holder '$odd' is written as a BARE PID - an unrecognised holder is "
              . 'ordinary, not a new kind of record, and the file three other '
              . 'tests read keeps its shape' );
    }

    Tira::CLI::Police::police_claim_singleton( $store,
        pid => 9002, holder => 'dashboard', alive => sub { 0 }, kill => sub { } );
    is( $read->(), '9002 dashboard',
        'and only the dashboard marks itself' );
}

# A FILE THAT SAYS SOMETHING ELSE IS AN ORDINARY CLAIM, not a dashboard. The
# dashboard is the holder nobody may kill, so anything the parser is unsure
# about must fall on the side of the ordinary rule rather than inherit that
# protection.
{
    my $store = tempdir( CLEANUP => 1 );
    my $path  = Tira::CLI::Police::police_singleton_path($store);

    for my $written ( '9100 dashboard garbage', '9100 Dashboard', '9100 police', '9100' ) {
        open my $fh, '>', $path or die "$path: $!";
        print {$fh} $written;
        close $fh;

        my @killed;
        my $claim = Tira::CLI::Police::police_claim_singleton( $store,
            pid => 9200, alive => sub { 1 }, kill => sub { push @killed, $_[0] } );

        ok( !$claim->{yield},
            "a claim file reading '$written' does not buy the protection only an "
              . 'exact dashboard claim earns' );
        is_deeply( \@killed, [9100],
            'and the ordinary rule applies to it - TKT-486, unchanged' );
    }
}

done_testing();

__END__

=head1 NAME

519-two-terminals-to-watch-one-board.t - the dashboard and the bridge together

=head1 WHY

TKT-897, his own filing: serving the board and running police are two commands,
so watching one board takes two terminals.

=head1 WHAT IS ASSERTED

That C<--with-police> is declared by the parser, refused outside C<-o browser>
rather than accepted and ignored, reaches the serving path, and is documented in
both manuals.

=head1 WHAT IS NOT ASSERTED, AND WHY

The precedence. His second sentence asks that the dashboard's police always wins
and a later C<tira.police> loses and exits - which is the reverse of his own
TKT-486 ruling, and the reverse of what the board does today, where the newest
claimant kills the previous one. That is a decision rather than an
implementation detail, it is Q-117, and inferring it here would be this test
choosing a rule on his behalf.

Nor does anything here start a server. Whether the two really share a terminal
is a walkthrough step.

=cut
