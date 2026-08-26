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
is( $added->{status}, 0, 'a new task starts pending (0)' );
like( $added->{id}, qr/\ATSK-\d+\z/, 'and is given a TSK-NNN id' );
is( $added->{session}, '', 'with no session declared, it belongs to the shared list' );

my $listed = $tira->tasklist_list( project => $root );
is( scalar @{$listed}, 1, 'listing with no session sees the shared item' );
is( $listed->[0]{id}, $added->{id}, 'the one just added' );

# --- moving through the three states ----------------------------------------
my $moved = $tira->tasklist_update( project => $root, id => $added->{id}, status => 'working' );
is( $moved->{status}, 1, 'update moves it to working (1), accepting the word as input' );

my $moved_by_code = $tira->tasklist_update( project => $root, id => $added->{id}, status => 0 );
is( $moved_by_code->{status}, 0, 'update also accepts the numeric code directly, back to pending (0)' );

$tira->tasklist_update( project => $root, id => $added->{id}, status => 'done' );
my $after_done = $tira->tasklist_list( project => $root );
is( $after_done->[0]{status}, 2, 'and on to done (2)' );

eval { $tira->tasklist_update( project => $root, id => $added->{id}, status => 'nonsense' ) };
like( $@, qr/pending, working, done/, 'a status outside the three is refused, naming them' );

eval { $tira->tasklist_update( project => $root, id => $added->{id}, status => 9 ) };
like( $@, qr/pending, working, done/, 'an out-of-range numeric code is refused the same way' );

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

# --- TKT-539: a deliberate, explicit opt-in shows every session's items ----
# together, for a supervising agent that needs to check on several
# subagents without already knowing each one's session id.
my $everything = $tira->tasklist_list( project => $root, all_sessions => 1 );
is( scalar @{$everything}, 3, '--all-sessions returns every item across every session' );
my %by_session = map { $_->{session} => $_->{id} } @{$everything};
is( $by_session{'agent-a'}, $mine->{id}, 'agent-a\'s item is included, labeled with its own session' );
is( $by_session{'agent-b'}, $theirs->{id}, 'and agent-b\'s item, labeled with its own session' );
is( $by_session{''}, $added->{id}, 'and the shared item, labeled with an empty session' );

my ( $all_status, $all_out ) = cli( 'tasklist.list', '--all-sessions', '-o', 'json' );
is( $all_status, 0, 'tasklist.list --all-sessions dispatches' );
is( scalar @{ decode_json($all_out) }, 3, 'and returns every session\'s items via the CLI too' );

# --- TKT-541: discovering which sessions exist at all, without --all-sessions's
# flat dump - one row per session, item count, and a status breakdown, so a
# supervising agent can see who has what before drilling into --session/-all.
$tira->tasklist_update( project => $root, id => $theirs->{id}, status => 'done', session => 'agent-b' );
my $sessions = $tira->tasklist_sessions( project => $root );
is( scalar @{$sessions}, 3, 'one row per distinct session (agent-a, agent-b, shared)' );
my %by_id = map { $_->{session} => $_ } @{$sessions};
is( $by_id{'agent-a'}{count}, 1, 'agent-a has one item' );
is_deeply( $by_id{'agent-a'}{status}, { pending => 1, working => 0, done => 0 },
    'agent-a\'s one item is pending' );
is( $by_id{'agent-b'}{count}, 1, 'agent-b has one item' );
is_deeply( $by_id{'agent-b'}{status}, { pending => 0, working => 0, done => 1 },
    'agent-b\'s one item is now done' );
is( $by_id{''}{count}, 1, 'the shared session has one item' );
is( $sessions->[0]{count} >= $sessions->[-1]{count}, 1, 'sorted by item count descending' );

my ( $sessions_status, $sessions_out ) = cli( 'tasklist.sessions', '-o', 'json' );
is( $sessions_status, 0, 'tasklist.sessions dispatches' );
is( scalar @{ decode_json($sessions_out) }, 3, 'and returns the same 3 rows via the CLI' );

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
is( $via_cli->{status}, 0, 'and returns the new item' );

( $status, $out ) = cli( 'tasklist.list', '-o', 'json' );
is( $status, 0, 'tasklist.list dispatches' );
ok( ( grep { $_->{id} eq $via_cli->{id} } @{ decode_json($out) } ), 'and lists the item just added' );

( $status, $out ) = cli( 'tasklist.update', '--id', $via_cli->{id}, '--status', 'working', '-o', 'json' );
is( $status, 0, 'tasklist.update dispatches' );
is( decode_json($out)->{status}, 1, 'and moves the item' );

# Found adversarially: --status 0 (the numeric form, always a string once it
# arrives from the command line) was stored as the JSON string "0", unlike
# every other write path's real int - Test::More's is() could not have
# caught this, since "0" and 0 compare equal after decode_json; only the raw
# JSON text distinguishes a quoted value from a bare one.
( $status, $out ) = cli( 'tasklist.update', '--id', $via_cli->{id}, '--status', '0', '-o', 'json' );
is( $status, 0, 'tasklist.update --status 0 (numeric) dispatches' );
unlike( $out, qr/"status"\s*:\s*"0"/, 'and the status is stored as a bare int, not a quoted string' );
like( $out, qr/"status"\s*:\s*0\D/, 'the raw JSON really does show status as 0, unquoted' );

# TKT-523: the browser dashboard's Task List section needs to edit a task's
# own text in place - --text reaches the same command --status already does.
( $status, $out ) = cli( 'tasklist.update', '--id', $via_cli->{id}, '--text', 'Read it twice', '-o', 'json' );
is( $status, 0, 'tasklist.update --text dispatches' );
is( decode_json($out)->{text}, 'Read it twice', 'and updates the text' );

( $status, $out ) = cli( 'tasklist.update', '--id', $via_cli->{id}, '-o', 'json' );
isnt( $status, 0, 'tasklist.update refuses with neither --status nor --text' );

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

# --- TKT-507: ids never repeat, even after the list is fully emptied -------
# Found adversarially: minting an id from the current items alone reused
# a deleted item's id the moment the list emptied, since shift/pop/remove
# genuinely delete (unlike ticket/epic/sow, where nothing is ever truly
# removed, so their own id counters never see this).
{
    my $one = $tira->tasklist_add( project => $root, text => 'one', session => 'ids' );
    my $two = $tira->tasklist_add( project => $root, text => 'two', session => 'ids' );
    $tira->tasklist_shift( project => $root, session => 'ids' );
    $tira->tasklist_pop( project => $root, session => 'ids' );
    is( scalar @{ $tira->tasklist_list( project => $root, session => 'ids' ) }, 0,
        'the ids session list is now fully empty' );

    my $three = $tira->tasklist_add( project => $root, text => 'three', session => 'ids' );
    isnt( $three->{id}, $one->{id}, 'a fresh add after emptying the list does not reuse the first id' );
    isnt( $three->{id}, $two->{id}, 'nor the second' );
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

# --- TKT-508: prune removes only done items ---------------------------------
{
    my $p1 = $tira->tasklist_add( project => $root, text => 'stays pending', session => 'prune' );
    my $p2 = $tira->tasklist_add( project => $root, text => 'finishes', session => 'prune' );
    my $p3 = $tira->tasklist_add( project => $root, text => 'also finishes', session => 'prune' );
    $tira->tasklist_update( project => $root, id => $p2->{id}, status => 'done', session => 'prune' );
    $tira->tasklist_update( project => $root, id => $p3->{id}, status => 'done', session => 'prune' );

    my $pruned = $tira->tasklist_prune( project => $root, session => 'prune' );
    is( scalar @{$pruned}, 2, 'prune reports the two done items it removed' );
    my $remaining = $tira->tasklist_list( project => $root, session => 'prune' );
    is( scalar @{$remaining}, 1, 'only the pending item is left' );
    is( $remaining->[0]{id}, $p1->{id}, 'and it is the one that never finished' );

    is( scalar @{ $tira->tasklist_prune( project => $root, session => 'prune' ) }, 0,
        'pruning again finds nothing left to prune' );
}

# --- TKT-508: status is an int (0/1/2), a legacy string file still reads ---
{
    my $legacy_root = File::Spec->catdir( $tmp, 'legacy' );
    $tira->project_new(
        name => 'Legacy', dir => $legacy_root, members => ['claude'],
        columns => [ 'backlog, implement, done' ],
        sow_prefix => 'LSW', epic_prefix => 'LEP', ticket_prefix => 'LTK',
    );
    my $tasklist_json = File::Spec->catfile( $legacy_root, '.tira', 'tasklist.json' );
    open my $fh, '>:raw', $tasklist_json or die $!;
    print {$fh} '[{"id":"TSK-001","text":"old style","status":"working","session":"","refs":[],"order":1,"created_at":"x","last_updated":"x"}]';
    close $fh;

    my $legacy_list = $tira->tasklist_list( project => $legacy_root );
    is( $legacy_list->[0]{status}, 1, 'a pre-existing string status reads back as its int code' );

    $tira->tasklist_update( project => $legacy_root, id => 'TSK-001', status => 'done' );
    open my $raw, '<:raw', $tasklist_json or die $!;
    my $raw_content = do { local $/; <$raw> };
    close $raw;
    like( $raw_content, qr/"status"\s*:\s*2/, 'and the next write upgrades the file to the int form' );
}

# --- TKT-508: --sort on list, default and explicit --------------------------
{
    my $s1 = $tira->tasklist_add( project => $root, text => 'zzz', session => 'sortme' );
    my $s2 = $tira->tasklist_add( project => $root, text => 'aaa', session => 'sortme' );

    my $by_text = $tira->tasklist_list( project => $root, session => 'sortme', sort => 'text:asc' );
    is( $by_text->[0]{id}, $s2->{id}, 'an explicit --sort overrides the default' );

    my ( $status, $out ) = cli( 'tasklist.list', '--session', 'sortme', '--sort', 'text:desc', '-o', 'json' );
    is( $status, 0, 'tasklist.list --sort dispatches' );
    is( decode_json($out)->[0]{id}, $s1->{id}, 'and text:desc puts zzz first' );
}

# --- TKT-508: --attach on add, and the per-item attach/ref sub-verbs -------
{
    my $file_a = File::Spec->catfile( $tmp, 'a.txt' );
    my $file_b = File::Spec->catfile( $tmp, 'b.txt' );
    open my $fa, '>', $file_a or die $!; print {$fa} 'A'; close $fa;
    open my $fb, '>', $file_b or die $!; print {$fb} 'B'; close $fb;

    my $attached = $tira->tasklist_add(
        project => $root, text => 'has files', session => 'attach', attach => [ $file_a, $file_b ],
    );
    is( scalar @{ $attached->{attachments} }, 2, 'tasklist.add --attach stores both files' );

    my $file_c = File::Spec->catfile( $tmp, 'c.txt' );
    open my $fc, '>', $file_c or die $!; print {$fc} 'C'; close $fc;
    my $more = $tira->tasklist_task_attach_add(
        project => $root, id => $attached->{id}, files => [$file_c], session => 'attach',
    );
    is( scalar @{ $more->{attachments} }, 3, 'task.attach.add adds a third attachment to an existing item' );

    my $fewer = $tira->tasklist_task_attach_discard(
        project => $root, id => $attached->{id}, files => ['a.txt'], session => 'attach',
    );
    is( scalar @{ $fewer->{attachments} }, 2, 'task.attach.discard removes one by name' );
    ok( !( grep { $_->{original_filename} eq 'a.txt' } @{ $fewer->{attachments} } ),
        'and a.txt specifically is gone' );

    my $card_x = $tira->create_record( project => $root, type => 'ticket', title => 'X' );
    my $card_y = $tira->create_record( project => $root, type => 'ticket', title => 'Y' );
    my $linked = $tira->tasklist_task_ref_link(
        project => $root, id => $attached->{id}, refs => [ $card_x->{ref}, $card_y->{ref} ], session => 'attach',
    );
    is( scalar @{ $linked->{refs} }, 2, 'task.ref.link adds both refs' );

    my $unlinked = $tira->tasklist_task_ref_unlink(
        project => $root, id => $attached->{id}, refs => [ $card_x->{ref} ], session => 'attach',
    );
    is_deeply( $unlinked->{refs}, [ $card_y->{ref} ], 'task.ref.unlink removes just the one named' );

    eval { $tira->tasklist_task_attach_add( project => $root, id => 'TSK-999', files => [$file_a] ) };
    like( $@, qr/TSK-999/, 'attach.add on an id that does not exist is refused, naming it' );

    my ( $status, $out ) = cli(
        'tasklist.task.ref.link', '--id', $attached->{id}, '--ref', $card_x->{ref}, '--session', 'attach', '-o', 'json',
    );
    is( $status, 0, 'tasklist.task.ref.link dispatches' );
    ok( ( grep { $_ eq $card_x->{ref} } @{ decode_json($out)->{refs} } ), 'and adds the ref via the CLI too' );

    # Found adversarially: a pre-existing global guard (TKT-338/389) collapsed
    # --file down to a single value for every command except attachment.add,
    # silently breaking multiple --file on these two new commands even though
    # the engine methods themselves accepted an arrayref fine. Only a CLI-level
    # call with two --file flags exercises the option-parsing layer that bug
    # lived in - the direct-method tests above never would.
    my $file_d = File::Spec->catfile( $tmp, 'd.txt' );
    open my $fd, '>', $file_d or die $!; print {$fd} 'D'; close $fd;
    ( $status, $out ) = cli(
        'tasklist.task.attach.add', '--id', $attached->{id}, '--file', $file_c, '--file', $file_d,
        '--session', 'attach', '-o', 'json',
    );
    is( $status, 0, 'tasklist.task.attach.add with two --file flags dispatches' );
    is( scalar @{ decode_json($out)->{attachments} }, 3,
        'and both files land (c.txt already there from earlier, d.txt newly added)' );
}

# --- TKT-510: the 4 tasklist.task.* entrypoints live where the real DD
# dispatcher (Developer::Dashboard::SkillDispatcher::_nested_skill_path)
# actually looks for a 2-level-nested dotted command - a literal 'skills'
# segment before EVERY name past the first, not a plain subdirectory chain.
# t/390's own cli() dispatch tests above call Tira::CLI directly and would
# pass even with the wrong layout, since they never go through the real
# installed-skill path resolution - only this existence check, and the
# stricter dotted_command() guard in t/03-metadata.t, catch that class of
# bug. Confirmed live before this shipped: copying one file to the wrong
# layout reproduced "Command not found" against the actually-installed
# skill; moving it to this layout fixed it immediately.
for my $rel (
    'skills/tasklist/skills/task/skills/attach/cli/add',
    'skills/tasklist/skills/task/skills/attach/cli/discard',
    'skills/tasklist/skills/task/skills/ref/cli/link',
    'skills/tasklist/skills/task/skills/ref/cli/unlink',
) {
    ok( -f $rel, "$rel exists at the DD-required nested path" );
}

# --- TKT-563: tasklist.next --ref narrows to items linked to one or more
# specific cards, Michael's own words: "Get the next task specific from a
# single or multiple card." -------------------------------------------------
{
    my $unlinked  = $tira->tasklist_add( project => $root, text => 'Unlinked one', session => 'byref' );
    my $for_x     = $tira->tasklist_add( project => $root, text => 'For X', session => 'byref', refs => ['TKT-900'] );
    my $for_y     = $tira->tasklist_add( project => $root, text => 'For Y', session => 'byref', refs => ['TKT-901'] );

    is( $tira->tasklist_next( project => $root, session => 'byref' )->{id}, $unlinked->{id},
        'with no refs filter, next is still the globally-next pending item' );
    is( $tira->tasklist_next( project => $root, session => 'byref', refs => ['TKT-900'] )->{id}, $for_x->{id},
        'a single --ref narrows next to the item linked to that card' );
    is( $tira->tasklist_next( project => $root, session => 'byref', refs => ['TKT-901', 'TKT-900'] )->{id}, $for_x->{id},
        'several refs narrow next to whichever pending item is linked to any of them, in order' );
    is( $tira->tasklist_next( project => $root, session => 'byref', refs => ['TKT-999'] ), undef,
        'a ref nothing is linked to returns undef, not the wrong item' );

    my ( $status, $out ) = cli( 'tasklist.next', '--session', 'byref', '--ref', 'TKT-901', '-o', 'json' );
    is( $status, 0, 'tasklist.next --ref succeeds from the CLI' );
    is( decode_json($out)->{id}, $for_y->{id}, 'and returns the item linked to that ref' );
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
