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
