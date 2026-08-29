#!/usr/bin/env perl

# A --command given without a proof is parsed, accepted, and dropped.
#
# The owner asked for a state between picking a required action up and
# finishing it (TSK-194): "Agent can provide the command for a specific item
# first, so the user can see it is working on it". The item stays pending, the
# dashboard marks it, and the proof arrives afterwards once the command has
# actually produced something.
#
# Today that is not merely absent, it is silently swallowed. _proof_entries_for
# opens with
#
#   return undef if !defined $args{status} || lc( $args{status} ) ne 'done';
#
# so a --command arriving with --status pending never reaches the pair logic at
# all, and required_item_update then writes nothing because of
#
#   $entry->{proof} = $proof_entries if $proof_entries;
#
# The call succeeds. Nothing is stored. The caller is told nothing. That is the
# same shape as TKT-625's --dry-run: a flag parsed, accepted and discarded, with
# the caller given no reason to suspect it.
#
# WHAT THIS FILE DOES NOT DECIDE. Two things are open on the card and the
# assertions below are written to pass under either answer.
#
# Q-092 asks whether the engine fix also covers checklist items. It must,
# unless somebody deliberately adds a condition to keep discarding there - the
# early return is in a function BOTH families call. So this file asserts the
# required-action behaviour the card is scoped to, and says nothing about
# checklist items either way; the checklist assertions belong to whichever
# answer arrives.
#
# CHK-001 asks whether the later --proof must repeat its command or may attach
# to the one already recorded. Repeating is the simpler answer and keeps the
# pair rule intact. The assertions here only require that a recorded command
# SURVIVES until a proof arrives, which both answers give.
#
# The guard that matters most is the one that must NOT move: marking done still
# costs a matching --command/--proof pair. This adds a state before done; it
# does not weaken the gate, and three assertions here pass today and must go on
# passing.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'announce' );
my $tira = Tira->new( clock => sub { '2026-08-28T14:30:00+0100' } );
$tira->create_project( name => 'Announce project', dir => $root );

my $card = $tira->create_record(
    project => $root, author => 'claude', type => 'ticket', title => 'a card with work to announce' );
my $ref = $card->{ref};

$tira->required_item_add(
    project => $root, author => 'claude', ref => $ref,
    item => 'run the suite', status => 'pending', column => 'backlog' );

my ($seeded) = @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };
my $id = $seeded->{id};

# Established before anything is claimed about it: the item exists, is pending,
# and carries no evidence yet. Without this every assertion below could be
# passing about an item that was never created.
is( $seeded->{status}, 'pending', 'the item starts pending' );
is( $seeded->{proof}, undef, 'and carries no recorded evidence' );

# --- announcing a command, without a proof ----------------------------------
#
# The call already succeeds today. What it does not do is keep anything, which
# is why the assertion is about what is STORED rather than about whether the
# call threw - a test that only checked for an exception would pass against the
# silent discard.

my $announced = $tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $id,
    status => 'pending', command => ['prove -lr t'], source => 'required-action' );

is( $announced->{status}, 'pending',
    'announcing a command leaves the item pending - this is a state before done, not a way to finish' );

my ($stored) = grep { $_->{id} eq $id }
  @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };

isnt( $stored->{proof}, undef,
    'the announced command is kept, rather than parsed and thrown away' );

is( ref $stored->{proof}, 'ARRAY',
    'and kept in the same list the eventual proof pair goes into' );

is( $stored->{proof}[0]{command}, 'prove -lr t',
    'and it is the command that was given' );

# Passes today for the WRONG reason and is kept anyway, flagged rather than
# quietly counted as a green guard: $stored->{proof} is undef right now, so
# $stored->{proof}[0]{proof} is undef too and this is vacuously true. It only
# starts meaning something once the assertions above are green - which is the
# point at which it becomes the one that says the announced command has NOT
# been mistaken for a finished pair.
is( $stored->{proof}[0]{proof}, undef,
    'with no proof beside it yet, which is what marks the item as in progress' );

# --- and it survives until a proof arrives ----------------------------------
#
# The card leaves open whether the later --proof repeats its command or attaches
# to the recorded one. Either way the announcement must not vanish in between -
# a state that disappears on the next unrelated write is not a state.

$tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $id,
    item => 'run the suite, with coverage', source => 'required-action' );

my ($after) = grep { $_->{id} eq $id }
  @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };

is( $after->{proof}[0]{command}, 'prove -lr t',
    'an unrelated edit to the item does not discard the announced command' );

# --- and it is not mistaken for a done claim --------------------------------
#
# Found by a WARNING rather than by an assertion, which is why this exists.
# gate_passing_log entries read 'Marked "..." done: ...', and the two callers
# of _log_proof_gate fired on "did any evidence arrive" - true for an
# announcement once this change landed. So announcing a command wrote a gate
# entry claiming the item had been marked done, and the only outward sign was
# "Use of uninitialized value in concatenation at lib/Tira.pm line 5311",
# because an announced entry has no proof to interpolate.
#
# A false entry in the gate log is worse than a missing one: it is the record
# the board keeps of what was proved, and it would have said work was finished
# that had only been started.

my $log_after_announcing =
  @{ $tira->record_show( project => $root, ref => $ref )->{gate_passing_log} // [] };
is( $log_after_announcing, 0,
    'announcing a command writes no gate-log entry - it is not a claim that anything was proved' );

# --- what must NOT move -----------------------------------------------------
#
# Three guards on the gate this feature sits in front of. All three pass today
# and the card's scope_excluded says so in as many words: "Any change to what
# marking done costs - the command/proof pair stays required."

my $lone_command = do {
    local $@;
    eval {
        $tira->required_item_update(
            project => $root, author => 'claude', ref => $ref, id => $id,
            status => 'done', command => ['prove -lr t'], source => 'required-action' );
    };
    $@;
};
isnt( $lone_command, '',
    'marking DONE with a command and no proof is still refused' );

# The message, and getting this wrong once is why it is spelled out. There are
# TWO refusals in _proof_entries_for and they fire on different shapes: a
# missing side entirely gives "requires at least one --command/--proof pair",
# while an unequal COUNT of the two gives "Every --command needs a matching
# --proof". A lone --command has no proofs at all, so it meets the first. The
# first version of this assertion looked for the second and failed against
# correct behaviour.
like( $lone_command, qr/requires at least one --command\/--proof pair/,
    'and the refusal says a done claim needs a pair' );

# The other refusal, on its own shape, so both stay covered rather than one
# standing in for the other.
my $mismatched = do {
    local $@;
    eval {
        $tira->required_item_update(
            project => $root, author => 'claude', ref => $ref, id => $id,
            status => 'done', command => [ 'one', 'two' ], proof => ['only one'],
            source => 'required-action' );
    };
    $@;
};
like( $mismatched, qr/matching --proof/,
    'and an unequal number of commands and proofs is refused on its own terms' );

my $empty_pair = do {
    local $@;
    eval {
        $tira->required_item_update(
            project => $root, author => 'claude', ref => $ref, id => $id,
            status => 'done', command => [''], proof => [''], source => 'required-action' );
    };
    $@;
};
isnt( $empty_pair, '',
    'and an empty pair is still refused, as TKT-585 made it' );

my $finished = $tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $id,
    status => 'done', command => ['prove -lr t'], proof => ['All tests successful.'],
    source => 'required-action' );
is( $finished->{status}, 'done',
    'and a real pair still finishes the item' );

# The other half of the gate-log guard: restricting it to done-claims must not
# have stopped it recording them. A denial alone would pass against a log
# nothing ever writes to.
my $log_after_finishing =
  @{ $tira->record_show( project => $root, ref => $ref )->{gate_passing_log} // [] };
cmp_ok( $log_after_finishing, '>', 0,
    'while finishing it still writes one, so the log was narrowed and not silenced' );

# --- the shapes the announcement accepts and refuses ------------------------
#
# Written because the usage line makes a claim about these and the first line I
# wrote was wrong. [--command TEXT [--proof TEXT] ...] reads as "each command
# may independently carry a proof", which would make one command with a proof
# beside one without legal. It is not. Measured rather than assumed, and the
# line now nests the proofs as a group.

my $announce_several = do {
    local $@;
    eval { $tira->required_item_update(
        project => $root, author => 'claude', ref => $ref, id => $id,
        status => 'pending', command => [ 'first', 'second' ], source => 'required-action' ); };
    $@;
};
is( $announce_several, '',
    'several commands may be announced at once, with no proofs' );

my $partly_proved = do {
    local $@;
    eval { $tira->required_item_update(
        project => $root, author => 'claude', ref => $ref, id => $id,
        status => 'pending', command => [ 'first', 'second' ], proof => ['only one'],
        source => 'required-action' ); };
    $@;
};
like( $partly_proved, qr/matching --proof/,
    'but proving one of two is refused - either all of them are proved or none are' );

my $proof_alone = do {
    local $@;
    eval { $tira->required_item_update(
        project => $root, author => 'claude', ref => $ref, id => $id,
        status => 'pending', proof => ['a result'], source => 'required-action' ); };
    $@;
};
like( $proof_alone, qr/needs the --command it came from/,
    'and a proof with no command is refused whatever the status - it is a claim about a command nobody named' );

my $empty_announcement = do {
    local $@;
    eval { $tira->required_item_update(
        project => $root, author => 'claude', ref => $ref, id => $id,
        status => 'pending', command => [''], source => 'required-action' ); };
    $@;
};
like( $empty_announcement, qr/An empty command announces nothing/,
    'an empty announced command is refused, in words that fit an announcement rather than a done claim' );

# Announcing again replaces rather than accumulates, which is what makes the
# later proof "repeat its command" work: the pair overwrites the announcement.
my ($replaced) = grep { $_->{id} eq $id }
  @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };
is( scalar @{ $replaced->{proof} }, 2,
    'the last accepted announcement is what the item carries, replacing the one before' );

# --- announcing over a finished item ----------------------------------------
#
# A behaviour this change CREATED and which nothing on the card anticipated.
# Before TKT-628, `--status pending --command X` on a done item was inert: the
# command was discarded, so $entry->{proof} was never assigned and the proof
# pair survived untouched. Now the announcement is truthy, so it replaces.
#
# Deliberate rather than accepted. Re-announcing on a finished item is an
# explicit act - the caller passed both a status and a command - and it is how
# an item is re-opened to be worked again. What must not happen is the EVIDENCE
# disappearing, and it does not: gate_passing_log keeps it, which is exactly
# what that log exists for. Its own comment says so - "a required item can be
# renamed or removed, but what proved it done stays in the record the board
# already keeps for exactly this".
#
# The path that must stay inert is the move mechanism's backward reset, which
# sets status to pending with NO command - so _proof_entries_for returns undef
# and the proof is left alone. That is asserted below, because it is the one
# that happens without anybody asking for it.

$tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $id,
    status => 'done', command => ['prove -lr t'], proof => ['All tests successful.'],
    source => 'required-action' );

my $gate_entries_before =
  @{ $tira->record_show( project => $root, ref => $ref )->{gate_passing_log} // [] };

$tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $id,
    status => 'pending', command => ['a fresh command'], source => 'required-action' );

my ($reopened) = grep { $_->{id} eq $id }
  @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };

is( $reopened->{status}, 'pending',
    'announcing on a finished item re-opens it' );
is( $reopened->{proof}[0]{command}, 'a fresh command',
    'and the item now carries the new announcement' );
is( $reopened->{proof}[0]{proof}, undef,
    'which is an announcement, not a proof' );

my $gate_entries_after =
  @{ $tira->record_show( project => $root, ref => $ref )->{gate_passing_log} // [] };
is( $gate_entries_after, $gate_entries_before,
    'and what proved it before is still in the gate log - the evidence outlives the item field' );

# The inert path: a status change carrying no command must still leave a stored
# proof alone. This is what the move mechanism's backward reset does, and it
# runs without anybody asking, so it is the one that would lose evidence
# quietly if the early return were ever widened again.
$tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $id,
    status => 'done', command => ['prove -lr t'], proof => ['All tests successful.'],
    source => 'required-action' );
$tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $id,
    status => 'pending', source => 'required-action' );
my ($reset) = grep { $_->{id} eq $id }
  @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };
is( $reset->{proof}[0]{proof}, 'All tests successful.',
    'a status change with no command leaves the stored proof untouched, as the backward reset needs' );

# --- four defects the code review found, and I did not ----------------------
#
# All four share one cause: I reasoned about the new state in isolation and not
# about what already reads the field it writes. Every one of them is a path
# where something that was true of a proof pair is now false of an
# announcement, and nothing had been asked to notice.

# 1. ANNOUNCEMENTS CHARGED AS REUSED EVIDENCE.
#
# _refuse_reused_proof signatures a missing proof as the empty string, so two
# items announcing the SAME command in one column look like the same command
# and the same proof - and the second is refused as reuse. Announcing
# "prove -lr t" on two items is entirely ordinary; the reuse rule is about
# passing one piece of EVIDENCE off as two, and an announcement is not
# evidence yet.

$tira->required_item_add(
    project => $root, author => 'claude', ref => $ref,
    item => 'a second item in the same column', status => 'pending', column => 'backlog' );
my ($second) = grep { $_->{item} eq 'a second item in the same column' }
  @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };

$tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $id,
    status => 'pending', command => ['prove -lr t'], source => 'required-action' );

my $same_command_elsewhere = do {
    local $@;
    eval { $tira->required_item_update(
        project => $root, author => 'claude', ref => $ref, id => $second->{id},
        status => 'pending', command => ['prove -lr t'], source => 'required-action' ); };
    $@;
};
is( $same_command_elsewhere, '',
    'two items may announce the same command - an announcement is not evidence, so it cannot be reused evidence' );

# 2. AN ANNOUNCEMENT MUST NOT REPLACE REAL EVIDENCE ON AN ITEM THAT STAYS DONE.
#
# I found and asserted the deliberate re-open - status pending with a command.
# This is the path I missed: no --status at all, so the item stays done while
# its proof becomes a command-only entry. A done item whose evidence has
# quietly turned into an announcement is exactly what TKT-583 and TKT-585
# exist to prevent.

$tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $id,
    status => 'done', command => ['prove -lr t'], proof => ['All tests successful.'],
    source => 'required-action' );

my $renamed_with_command = do {
    local $@;
    eval { $tira->required_item_update(
        project => $root, author => 'claude', ref => $ref, id => $id,
        item => 'renamed while done', command => ['a new command'],
        source => 'required-action' ); };
    $@;
};
my ($still_done) = grep { $_->{id} eq $id }
  @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };
ok( $renamed_with_command ne '' || defined $still_done->{proof}[0]{proof},
    'an item that stays done keeps evidence behind its done claim - the announcement is refused, or the proof survives' );

# 3. EVIDENCE STORED WITH NO GATE ENTRY.
#
# The gate-log condition reads $args{status}, which is what the CALLER passed,
# not what the entry ended up as. So a done item given a fresh pair without
# repeating --status stores the evidence and logs nothing - and the gate log is
# the record that outlives the item.

$tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $id,
    status => 'done', command => ['prove -lr t'], proof => ['All tests successful.'],
    source => 'required-action' );
my $log_before_retitle =
  @{ $tira->record_show( project => $root, ref => $ref )->{gate_passing_log} // [] };

eval { $tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $id,
    item => 'retitled with fresh evidence', command => ['prove -lr t'], proof => ['Result: PASS'],
    source => 'required-action' ); };

my ($retitled) = grep { $_->{id} eq $id }
  @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };
my $log_after_retitle =
  @{ $tira->record_show( project => $root, ref => $ref )->{gate_passing_log} // [] };

ok( ( $retitled->{proof}[0]{proof} // '' ) ne 'Result: PASS'
      || $log_after_retitle > $log_before_retitle,
    'evidence stored against a done item is logged - what is recorded and what the log records cannot diverge' );

# 4. THE REFUSALS NAME THE RIGHT HALF.
#
# Two combinations carried the wrong text. A blank --proof supplied alongside a
# real command, on a non-done call, was told "An empty command announces
# nothing" - naming the half that was fine.

my $blank_proof_announcing = do {
    local $@;
    eval { $tira->required_item_update(
        project => $root, author => 'claude', ref => $ref, id => $second->{id},
        status => 'pending', command => ['a command'], proof => ['   '],
        source => 'required-action' ); };
    $@;
};
like( $blank_proof_announcing, qr/--proof/,
    'a blank proof is refused by naming the proof, not the command that was fine' );
unlike( $blank_proof_announcing, qr/An empty command announces nothing/,
    'and not with the message for an empty command' );

# --- the edges of the overwrite guard ---------------------------------------
#
# Verified in a container after the code review asked about them, and asserted
# here rather than left as a one-off run. Each is a case where the guard could
# plausibly fire when it should not, or not fire when it should.

# An item whose stored proof is ITSELF only an announcement has no evidence to
# protect, so announcing over it must be allowed. The guard tests the stored
# array for a real proof rather than for any content at all.
my $c_only = $tira->required_item_add(
    project => $root, author => 'claude', ref => $ref,
    item => 'announced twice', status => 'pending', column => 'backlog' );
my ($twice) = grep { $_->{item} eq 'announced twice' }
  @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };
$tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $twice->{id},
    status => 'pending', command => ['first'], source => 'required-action' );
my $over_announcement = do {
    local $@;
    eval { $tira->required_item_update(
        project => $root, author => 'claude', ref => $ref, id => $twice->{id},
        item => 'renamed', command => ['second'], source => 'required-action' ); };
    $@;
};
is( $over_announcement, '',
    'announcing over an item whose stored proof is only an announcement is allowed - there is no evidence to protect' );

# And the refusal must leave the record exactly as it was. The reuse check runs
# before this die and can write repeated_confirm to the record on its own path,
# so a refusal here could plausibly leave a half-written entry behind.
my $guarded = $tira->required_item_add(
    project => $root, author => 'claude', ref => $ref,
    item => 'guarded item', status => 'pending', column => 'backlog' );
my ($g) = grep { $_->{item} eq 'guarded item' }
  @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };
$tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $g->{id},
    status => 'done', command => ['proved it'], proof => ['real output'],
    source => 'required-action' );
eval { $tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $g->{id},
    item => 'renamed while done', command => ['a new command'],
    source => 'required-action' ); };
my ($untouched) = grep { $_->{id} eq $g->{id} }
  @{ $tira->record_show( project => $root, ref => $ref )->{required_items} };
is( $untouched->{status}, 'done',
    'a refused announcement leaves the status alone' );
is( $untouched->{proof}[0]{proof}, 'real output',
    'and leaves the evidence alone' );
is( $untouched->{item}, 'guarded item',
    'and leaves the item text alone - the refusal is not a partial write' );
ok( !exists $untouched->{repeated_confirm},
    'and writes no confirmation code, though the reuse check runs before the refusal' );

# --- a command travels with a status, not entirely alone --------------------
#
# The documentation review caught me claiming a --command "may arrive alone".
# It may not: both update commands refuse a call that changes nothing, and that
# guard predates this feature and is not relaxed by it. Every test above passes
# a status, so nothing had exercised the bare case and the prose went unchecked.
#
# Asserted rather than only corrected in prose, because the sentence I wrote is
# the sentence somebody will try.

my $bare_command = do {
    local $@;
    eval { $tira->required_item_update(
        project => $root, author => 'claude', ref => $ref, id => $id,
        command => ['prove -lr t'], source => 'required-action' ); };
    $@;
};
like( $bare_command, qr/item or status is required/,
    'a --command with no --status and no --item is refused - the older guard still applies' );

# And the shape the card actually asks for works: a status the item already
# has, restated so the call is changing something, with the command beside it.
$tira->required_item_update(
    project => $root, author => 'claude', ref => $ref, id => $id,
    status => 'pending', source => 'required-action' );
my $with_status = do {
    local $@;
    eval { $tira->required_item_update(
        project => $root, author => 'claude', ref => $ref, id => $id,
        status => 'pending', command => ['prove -lr t'], source => 'required-action' ); };
    $@;
};
is( $with_status, '',
    'and restating the status the item already has is what carries the command' );

# --- and the dashboard shows it -------------------------------------------
#
# The half the owner actually sees, and the reason he asked: "so the user can
# see it is working on it". The engine keeping the command is invisible to him;
# the clock is the feature.
#
# Read out of the module the way t/417 reads it - the dashboard JS is a literal
# inside lib/Tira.pm - with the POD stripped first, so prose that quotes the
# markup while explaining it does not satisfy a test about code. Same reason,
# same method, and t/417 records what happens without it: documenting a change
# turned its own test red.
#
# Written in `implement` rather than in `tests-red`, and said so rather than
# backdated: the engine work is what settled the shape the renderer has to read
# - an entry carrying a command and no proof - and writing this assertion
# before that shape existed would have pinned a guess.

# TKT-703 moved the dashboard's front-end out of lib/Tira.pm and into
# lib/Tira/views, so this reads the scripts themselves. That is a better
# subject than it had: the note below explains that stripping POD was not
# enough because prose also lives in Perl comments, and a .js file has neither.
# The check that the subject is real moved with it - a directory that has
# stopped holding scripts must fail here rather than pass with nothing to read.
my $views = File::Spec->catdir( 'lib', 'Tira', 'views' );
opendir my $dh, $views or die "$views: $!";
my @scripts = sort grep { /\.js\z/ } readdir $dh;
closedir $dh;
cmp_ok( scalar @scripts, '>=', 5,
    'the dashboard ships its scripts as files - found ' . scalar(@scripts) );

my $js = '';
for my $name (@scripts) {
    open my $fh, '<:encoding(UTF-8)', File::Spec->catfile( $views, $name )
      or die "$name: $!";
    local $/;
    $js .= <$fh>;
    close $fh;
}

like( $js, qr/card-required/, 'the dashboard JS was read' );
cmp_ok( length $js, '>', 50_000,
    'and it is the whole front-end rather than one file - ' . length($js) . ' bytes' );

# The predicate, not the glyph: the card asks for a clock, and which clock is a
# styling decision. What must exist is the dashboard deciding that an item with
# a command and no proof is in a state of its own - neither done nor untouched.
#
# Matched as a JS declaration rather than as the bare word. The first version
# looked for /isAnnounced|announced/ and passed immediately - against the Perl
# COMMENT I had just written in _proof_entries_for explaining the feature.
# Stripping POD is not enough when the file is Perl wrapped around JavaScript:
# prose lives in comments too, and only something shaped like code can tell the
# two apart. Same fault t/417 met from the POD side, one layer in.
like( $js, qr/const isAnnounced\s*=/,
    'the dashboard can tell an announced item from an untouched one' );

# Three states became four, and the ordering still has to hold: exempt wins
# over everything, done over announced, announced over untouched. Asserted as
# the icon expression carrying four outcomes rather than by naming characters,
# so a different clock does not fail this.
my ($icon_line) = $js =~ /(const icon=[^;]{0,220};)/;
isnt( $icon_line, undef, 'the icon is still chosen in one place' );
my $branches = () = ( $icon_line // '' ) =~ /\?/g;
cmp_ok( $branches, '>=', 3,
    'and it now chooses between four states rather than three' );

done_testing();

__END__

=head1 NAME

t/418-a-command-announced-and-thrown-away.t - a required action must be able to
record its command before its proof

=head1 DESCRIPTION

The owner asked for a state between picking a required action up and finishing
it: record the command first, leave the item pending, and let the proof arrive
once the command has produced something.

Today a C<--command> given with C<--status pending> is parsed, accepted and
discarded. C<_proof_entries_for> returns C<undef> unless the status is exactly
C<done>, and C<required_item_update> writes evidence only when that function
returns something. The call succeeds, nothing is stored, and the caller is told
nothing - the same shape as TKT-625's ignored C<--dry-run>.

This file asserts what is stored rather than whether the call threw, because a
test that only watched for an exception would pass against the silent discard.

It deliberately says nothing about checklist items. The early return is in a
function both families call, so the engine fix reaches both unless somebody
adds a condition to keep discarding for checklists - which is Q-092, and the
assertions here are written to pass under either answer.

The last four assertions pass today and must go on passing: marking done still
costs a matching pair, an empty pair is still refused, and a real pair still
finishes the item. This adds a state before done; it does not weaken the gate.

=cut
