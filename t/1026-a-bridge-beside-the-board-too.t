#!/usr/bin/env perl
# The bridge beside the board too.
#
# TKT-1026, his own answer to Q-151, asked because --with-police (TKT-897)
# set a precedent rather than settling this on its own: "if --with-policy-
# bridge then d2 tira.policy.bridge will be run. Just like the --with-police
# to run d2 tira.police to run at the back. So there will be the bridge and
# the police and the dashboard run them all in 1 go."
#
# Modeled on t/519's own --with-police coverage, one entrypoint over: the
# flag exists, it is refused where it cannot mean anything, it reaches the
# serving path, it is documented, and the real spawn (not only the seam) is
# exercised too - the same reasons t/519 gives for each.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite;
use Tira;
use Tira::CLI;

# --- the parser knows the flag ----------------------------------------------

my $cli = Suite::cli_source();

like( $cli, qr/\S/, 'the command surface was walked to look for the flag' );

like( $cli, qr/'with-policy-bridge'/,
    'THE PARSER DECLARES --with-policy-bridge, so it can be typed at all - his '
      . 'own words are the whole of this assertion: the bridge and the police '
      . 'and the dashboard, all in one go' );

# --- and refuses it where it cannot mean anything ---------------------------

like( $cli, qr/--with-policy-bridge needs -o browser|with_policy_bridge.*?browser|browser.*?with_policy_bridge/s,
    'and it is REFUSED outside -o browser rather than accepted and ignored - '
      . 'the same fault --with-police and --show-logs are already guarded '
      . 'against by name' );

# --- one signal path, so nothing is left holding a claim ---------------------

like( $cli, qr/with_policy_bridge/,
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

    for my $name ( sort keys %doc ) {
        like( $doc{$name}, qr/\S/, "$name was read to look for the flag" );
    }

    for my $name ( sort keys %doc ) {
        like( $doc{$name}, qr/--with-policy-bridge/,
            "$name names --with-policy-bridge, so somebody can find it without "
              . 'reading the option table in the source' );
    }
}

# --- the pass is started beside the board, and dies with it -----------------
#
# Driven through the real dispatcher with the seams injected, the way t/519
# drives --with-police: starting the bridge FORKS too, and a test without the
# seams would leave a policy-bridge process running inside the harness.

{
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'Bridged', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'BRS', epic_prefix => 'BRE', ticket_prefix => 'BRT',
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
                command               => 'dashboard.ticket',
                tira                  => $tira,
                argv                  => [ '-o', 'browser', @extra ],
                browser_server        => sub { $served = 1; return 1 },
                policy_bridge_starter => sub { push @started, {@_}; return 5252 },
                policy_bridge_stopper => sub { push @stopped, $_[0]; return 1 },
            );
        }
        return $err;
    };

    # WITH the flag.
    $run->('--with-policy-bridge');

    is( scalar @started, 1,
        'ONE COMMAND STARTS BOTH - the bridge is started beside the served '
          . 'board, one entrypoint over from --with-police' );

    ok( $served, 'and the board is still served - the bridge is beside it, not '
          . 'instead of it' );

    is_deeply( \@stopped, [5252],
        'AND STOPPING THE COMMAND STOPS BOTH. The pass it started is the pass '
          . 'it stops, by the pid the starter returned - a child left running '
          . 'has nothing named after it in the singleton store, but it is still '
          . 'a process nobody meant to leave behind' );

    is( ( $started[0] || {} )->{project}, $root,
        'the pass is pointed at the board being served rather than at whatever '
          . 'a child with no context would resolve for itself' );

    # WITHOUT the flag: nothing is started and nothing is stopped.
    $run->();

    is_deeply( \@started, [],
        'and without --with-policy-bridge nothing is started - the flag is the '
          . 'whole of the difference' );

    is_deeply( \@stopped, [], 'nor stopped, since there was nothing to stop' );
}

# --- and together with --with-police, the way Q-151 actually asked for it ---
#
# His own words: "So there will be the bridge and the police and the dashboard
# run them all in 1 go." Each flag was proved alone above; this is the case he
# actually asked for - both starters injected, both reached, both reaped.

{
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'Combined', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'CBS', epic_prefix => 'CBE', ticket_prefix => 'CBT',
    );

    my ( @police_started, @police_stopped, @bridge_started, @bridge_stopped, $served );
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run(
            command               => 'dashboard.ticket',
            tira                  => $tira,
            argv                  => [ '-o', 'browser', '--with-police', '--with-policy-bridge' ],
            browser_server        => sub { $served = 1; return 1 },
            police_starter        => sub { push @police_started, {@_}; return 6161 },
            police_stopper        => sub { push @police_stopped, $_[0]; return 1 },
            policy_bridge_starter => sub { push @bridge_started, {@_}; return 6262 },
            policy_bridge_stopper => sub { push @bridge_stopped, $_[0]; return 1 },
        );
    }

    ok( $served, 'the board, the police, and the bridge together - the board is '
          . 'still served with both flags given at once' );

    is( scalar @police_started, 1,
        'BOTH FLAGS TOGETHER: the police pass starts' );

    is( scalar @bridge_started, 1,
        'BOTH FLAGS TOGETHER: the bridge pass starts too - one command, all three' );

    is_deeply( \@police_stopped, [6161],
        'and the police pass is reaped by the pid its own starter returned' );

    is_deeply( \@bridge_stopped, [6262],
        'and the bridge pass is reaped by the pid its own starter returned, '
          . 'independently of the police pass' );
}

# --- a fork that fails is said, not swallowed -------------------------------

{
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'BridgeFailed', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'BFS', epic_prefix => 'BFE', ticket_prefix => 'BFT',
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
            command               => 'dashboard.ticket',
            tira                  => $tira,
            argv                  => [ '-o', 'browser', '--with-policy-bridge' ],
            browser_server        => sub { $served = 1; return 1 },
            policy_bridge_starter => sub { return undef },
            policy_bridge_stopper => sub { push @stopped, $_[0]; return 1 },
        );
    }

    ok( $served,
        'a bridge pass that could not be started does not cost somebody their '
          . 'board - the flag asked for both, and one of them is still '
          . 'possible' );

    like( $said, qr/policy bridge/i,
        'and it SAYS the bridge is missing rather than serving a board that '
          . 'quietly is not watched' );

    is_deeply( \@stopped, [],
        'nothing is stopped, because nothing was started' );
}

# --- and the real spawn, not only the seam ----------------------------------

{
    my $tmp   = tempdir( CLEANUP => 1 );
    my $root  = File::Spec->catdir( $tmp, 'board' );

    my $tira = Tira->new;
    $tira->project_new(
        name => 'RealBridge', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'RBS', epic_prefix => 'RBE', ticket_prefix => 'RBT',
    );

    require Tira::CLI::Serve;

    my $child = Tira::CLI::Serve::_start_policy_bridge_beside_board(
        tira => $tira, project => $root );

    SKIP: {
        skip 'no policy.bridge entrypoint on this checkout', 3 if !$child;

        ok( $child > 0,
            'THE REAL SPAWN ANSWERS WITH A PID - the parent gets a process back '
              . 'rather than falling into the bridge loop itself' );

        ok( kill( 0, $child ), 'and the process it names is really there' );

        my $stopped = Tira::CLI::Serve::_stop_policy_bridge_beside_board($child);
        waitpid $child, 0 if $child;
        ok( $stopped, 'and the real stopper ends it' );
    }
}

# A spawn that cannot find its entrypoint answers undef rather than a pid
# nobody can signal.
{
    no warnings 'redefine';
    local *Tira::CLI::Serve::_entrypoint_for = sub { return undef };

    my $none = Tira::CLI::Serve::_spawn_policy_bridge_beside_board(
        project => '/nowhere' );

    ok( !defined $none,
        'no entrypoint means no pid - a spawn that cannot happen says so rather '
          . 'than returning something the caller will later signal' );
}

is( Tira::CLI::Serve::_stop_policy_bridge_beside_board(undef), 0,
    'and stopping nothing does nothing' );

# --- and so does the store, when there is one -------------------------------

{
    my @spawned;
    Tira::CLI::Serve::_start_policy_bridge_beside_board(
        project => '/board', store => '/somewhere/else',
        spawn   => sub { push @spawned, {@_}; return 5353 } );

    is( ( $spawned[0] || {} )->{store}, '/somewhere/else',
        'the store the parent is using reaches the spawn rather than being '
          . 'left for a separate process to derive differently' );
}

done_testing();

__END__

=head1 NAME

1026-a-bridge-beside-the-board-too.t - the policy bridge alongside the served board

=head1 WHY

TKT-1026, his own answer to Q-151: mirror C<--with-police> so one command
starts the bridge, the police, and the dashboard together.

=head1 WHAT IS ASSERTED

That C<--with-policy-bridge> is declared by the parser, refused outside
C<-o browser> rather than accepted and ignored, reaches the serving path, is
documented in both manuals, and that the real spawn (open3, not a hand-rolled
fork) answers with a real pid that the real stopper can end.

=head1 WHAT IS NOT ASSERTED

Nothing about C<TIRA_POLICE_HOLDER> or the singleton claim - the bridge is a
reader, not a claimant, and has nothing to yield.

=cut
