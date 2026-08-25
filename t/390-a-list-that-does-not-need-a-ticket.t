#!/usr/bin/env perl
# TKT-504. "Since TaskList not working, Create this simple task list
# feature to Tira, d2 tira.tasklist.add." Settled via Q-075: a parallel
# system, totally separate from ticket/epic/sow. Free text items, only
# three columns (pending/working/done), can link to multiple cards - like
# a tiny ticket, but without gates/checklists/required-actions. Each agent
# declares its own agent_session id to support subagent mode - each
# subagent gets its own private list; with none declared, single-agent
# mode uses one shared list.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T20:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Tasked', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'TAS', epic_prefix => 'TAE', ticket_prefix => 'TAT',
);

# --- a single-agent board uses one shared list, with no session named ------
my $added = $tira->tasklist_add( project => $root, text => 'Read the README' );
is( $added->{status}, 'pending', 'a new task starts pending' );
like( $added->{id}, qr/\ATSK-\d+\z/, 'and is given a TSK-NNN id' );
is( $added->{session}, '', 'with no session declared, it belongs to the shared list' );

my $listed = $tira->tasklist_list( project => $root );
is( scalar @{$listed}, 1, 'listing with no session sees the shared item' );
is( $listed->[0]{id}, $added->{id}, 'the one just added' );

# --- moving through the three states ----------------------------------------
my $moved = $tira->tasklist_update( project => $root, id => $added->{id}, status => 'working' );
is( $moved->{status}, 'working', 'update moves it to working' );

$tira->tasklist_update( project => $root, id => $added->{id}, status => 'done' );
my $after_done = $tira->tasklist_list( project => $root );
is( $after_done->[0]{status}, 'done', 'and on to done' );

eval { $tira->tasklist_update( project => $root, id => $added->{id}, status => 'nonsense' ) };
like( $@, qr/pending, working, done/, 'a status outside the three is refused, naming them' );

eval { $tira->tasklist_update( project => $root, id => 'TASK-999', status => 'done' ) };
like( $@, qr/TASK-999/, 'an id that does not exist is refused, naming it' );

# --- two sessions never see each other's items ------------------------------
my $mine = $tira->tasklist_add( project => $root, text => 'My own step', session => 'agent-a' );
my $theirs = $tira->tasklist_add( project => $root, text => 'A different step', session => 'agent-b' );

my $for_a = $tira->tasklist_list( project => $root, session => 'agent-a' );
is( scalar @{$for_a}, 1, 'agent-a sees only its own item' );
is( $for_a->[0]{id}, $mine->{id}, 'the one it added' );

my $for_b = $tira->tasklist_list( project => $root, session => 'agent-b' );
is( scalar @{$for_b}, 1, 'agent-b sees only its own item' );
is( $for_b->[0]{id}, $theirs->{id}, 'the one it added' );

my $shared_again = $tira->tasklist_list( project => $root );
is( scalar @{$shared_again}, 1, 'the shared (no-session) list still shows only the shared item' );

# --- an item can link to existing cards -------------------------------------
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Linked card' );
my $linked = $tira->tasklist_add( project => $root, text => 'Step tied to a ticket', refs => [ $card->{ref} ] );
is_deeply( $linked->{refs}, [ $card->{ref} ], 'refs are stored on the item' );

# --- text is required --------------------------------------------------------
eval { $tira->tasklist_add( project => $root, text => '' ) };
like( $@, qr/text is required/i, 'an empty task refuses rather than storing nothing' );

# --- TKT-505: an env var stands in for --session, so multi-agent mode does --
# not have to type it on every call. An explicit --session still wins.
{
    local $ENV{TIRA_AGENT_SESSION} = 'agent-c';
    my $via_env = $tira->tasklist_add( project => $root, text => 'From the environment' );
    is( $via_env->{session}, 'agent-c', 'with no --session, the env var is used' );

    my $for_c = $tira->tasklist_list( project => $root );
    is( scalar @{$for_c}, 1, 'listing with no --session reads the same env var' );
    is( $for_c->[0]{id}, $via_env->{id}, 'and sees the item just added' );

    my $overridden = $tira->tasklist_add( project => $root, text => 'Explicit wins', session => 'agent-d' );
    is( $overridden->{session}, 'agent-d', 'an explicit --session still overrides the env var' );
}

# --- the three CLI dispatchers reach the same engine ------------------------

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME}   = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    my $status = Tira::CLI->run( command => $command, argv => \@argv );
    return ( $status, $out, $err );
}

my ( $status, $out ) = cli( 'tasklist.add', '--text', 'From the CLI', '-o', 'json' );
is( $status, 0, 'tasklist.add dispatches' );
my $via_cli = decode_json($out);
is( $via_cli->{status}, 'pending', 'and returns the new item' );

( $status, $out ) = cli( 'tasklist.list', '-o', 'json' );
is( $status, 0, 'tasklist.list dispatches' );
ok( ( grep { $_->{id} eq $via_cli->{id} } @{ decode_json($out) } ), 'and lists the item just added' );

( $status, $out ) = cli( 'tasklist.update', '--id', $via_cli->{id}, '--status', 'working', '-o', 'json' );
is( $status, 0, 'tasklist.update dispatches' );
is( decode_json($out)->{status}, 'working', 'and moves the item' );

# --- TKT-507: array-list operations, on a fresh queue -----------------------
{
    my $a = $tira->tasklist_add( project => $root, text => 'A', session => 'arr' );
    my $b = $tira->tasklist_add( project => $root, text => 'B', session => 'arr' );
    my $c = $tira->tasklist_add( project => $root, text => 'C', session => 'arr' );

    my $peek = $tira->tasklist_next( project => $root, session => 'arr' );
    is( $peek->{id}, $a->{id}, 'next peeks at the front (A) without removing it' );
    is( scalar @{ $tira->tasklist_list( project => $root, session => 'arr' ) }, 3,
        'and nothing was removed' );

    my $shifted = $tira->tasklist_shift( project => $root, session => 'arr' );
    is( $shifted->{id}, $a->{id}, 'shift returns the front (A)' );
    is( scalar @{ $tira->tasklist_list( project => $root, session => 'arr' ) }, 2,
        'and removes it - B and C remain' );

    my $popped = $tira->tasklist_pop( project => $root, session => 'arr' );
    is( $popped->{id}, $c->{id}, 'pop returns the back (C)' );
    is( scalar @{ $tira->tasklist_list( project => $root, session => 'arr' ) }, 1,
        'and removes it - only B remains' );

    my $d = $tira->tasklist_unshift( project => $root, session => 'arr', text => 'D' );
    is( $tira->tasklist_next( project => $root, session => 'arr' )->{id}, $d->{id},
        'unshift places a new item at the very front, ahead of B' );

    my $e = $tira->tasklist_slice( project => $root, session => 'arr', text => 'E', position => 1 );
    my $order = $tira->tasklist_list( project => $root, session => 'arr' );
    is( $order->[1]{id}, $e->{id}, 'slice inserts at the given position - D, E, B' );
    is( scalar @{$order}, 3, 'and the queue now holds three items' );

    $tira->tasklist_remove( project => $root, session => 'arr', id => $d->{id} );
    my $after_remove = $tira->tasklist_list( project => $root, session => 'arr' );
    is( scalar @{$after_remove}, 2, 'remove deletes an item entirely' );
    ok( !( grep { $_->{id} eq $d->{id} } @{$after_remove} ), 'the removed item is gone, not merely marked done' );

    eval { $tira->tasklist_remove( project => $root, session => 'arr', id => 'TSK-999' ) };
    like( $@, qr/TSK-999/, 'removing an id that does not exist is refused, naming it' );

    is( $tira->tasklist_next( project => $root, session => 'sep' ), undef,
        'next on a session with nothing pending returns undef, not an error' );

    eval { $tira->tasklist_slice( project => $root, session => 'arr', text => 'F', position => -1 ) };
    like( $@, qr/[Pp]osition must not be negative/,
        'a negative position is refused, not a raw splice crash' );
}

# --- TKT-507: importing a card's pending required-actions/checklist --------
{
    my $source_card = $tira->create_record( project => $root, type => 'ticket', title => 'Has pending work' );
    $tira->required_item_add(
        project => $root, ref => $source_card->{ref}, item => 'Fill in acceptance criteria',
        status => 'pending', column => $source_card->{column}, author => 'claude',
    );
    $tira->checklist_add(
        project => $root, ref => $source_card->{ref}, item => 'Write the red test', status => 'pending',
        author => 'claude',
    );
    $tira->checklist_add(
        project => $root, ref => $source_card->{ref}, item => 'Already done, skip me', status => 'done',
        author => 'claude',
    );

    my $imported = $tira->tasklist_import( project => $root, ref => $source_card->{ref}, session => 'imp' );
    is( scalar @{$imported}, 2, 'imports only the two pending entries, not the done one' );
    my $imported_list = $tira->tasklist_list( project => $root, session => 'imp' );
    is( scalar @{$imported_list}, 2, 'both land in the imp session list' );
    is_deeply( $imported_list->[0]{refs}, [ $source_card->{ref} ], 'each item is linked back to the source card' );

    my $again = $tira->tasklist_import( project => $root, ref => $source_card->{ref}, session => 'imp' );
    is( scalar @{$again}, 0, 're-importing the same card is idempotent - nothing new' );
    is( scalar @{ $tira->tasklist_list( project => $root, session => 'imp' ) }, 2,
        'the list is unchanged after the repeat import' );

    my ( $status, $out ) = cli( 'tasklist.import', '--ref', $source_card->{ref}, '--session', 'imp-cli', '-o', 'json' );
    is( $status, 0, 'tasklist.import dispatches' );
    is( scalar @{ decode_json($out) }, 2, 'and imports via the CLI too' );
}

done_testing;

__END__

=head1 NAME

390-a-list-that-does-not-need-a-ticket.t - a lightweight, session-scoped task list separate from ticket/epic/sow

=head1 DESCRIPTION

TKT-504: a parallel, free-text task list with three fixed states
(pending/working/done), deliberately lighter than a ticket - no gates,
checklists, or required-actions. Items are scoped by C<session>: two
distinct session ids never see each other's items, and no session at all
is the single-agent default, one shared list. An item may optionally link
to existing tickets/epics/sows via C<refs>.

=cut
