#!/usr/bin/env perl

# A task says one thing about a card and the board says another, and nothing
# notices.
#
# The owner asked for a 30-minute check covering three things (TSK-194's
# sibling, TSK-214): that each task's status is correct, which tasks have no
# card linked, and which tasks say working while the card they name sits in
# backlog - reported on the policy bridge so the agent deals with it rather
# than somebody remembering to look.
#
# Half exists. task-unlinked (TKT-547) fires on a task with no card. The other
# half does not: a task can say working while its card is in backlog, done,
# discarded or already pushed, and nothing says so - the board and the queue
# disagree and only a person reading both notices.
#
# Measured by hand across 51 tasks and 47 cards when the card was raised: seven
# mismatches, five tasks saying working whose cards had just moved to push, one
# saying pending whose card was in implement, and one card carrying two tasks.
#
# THE COLUMN SET IS THE WHOLE DESIGN, and getting it wrong is not hypothetical -
# the owner's own reference script gets it wrong. Its working set is
#
#   WORKING={'next-to-work-on','tests-red','implement','verify','document'}
#
# and I have watched that one line produce seven false lines out of eight,
# every thirty minutes, all afternoon. A card in next-to-work-on is QUEUED. The
# owner puts cards there to say what comes next; nobody has started them; a
# task saying pending is the board telling the truth.
#
# So the rule takes its columns rather than assuming them, the way card-duration
# and wip-limit already do. The board cannot infer this: backlog and discard are
# marked protected and next-to-work-on is not, so "not protected" would sweep it
# straight back in. Which columns mean somebody is working is a statement about
# how a board is run, and the board is where it should be declared.
#
# What this file does NOT assert: that the mismatch is fixed. scope_excluded is
# explicit - "Fixing the mismatches automatically - the rule reports and the
# agent deals with it, which is what he asked for."

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'queue' );
my $store = File::Spec->catdir( $tmp, 'police-store' );
my $tira = Tira->new( clock => sub { '2026-08-28T16:00:00+0100' } );
$tira->project_new(
    name => 'Queue and board', dir => $root, members => ['claude'],
    columns => ['backlog, next-to-work-on, implement, verify, push, done'],
    sow_prefix => 'QSW', epic_prefix => 'QEP', ticket_prefix => 'QTK',
);

sub card_in {
    my ( $title, $column ) = @_;
    my $card = $tira->create_record(
        project => $root, author => 'claude', type => 'ticket', title => $title );
    return $card if $column eq 'backlog';
    $tira->record_move(
        project => $root, author => 'claude', ref => $card->{ref}, column => $column );
    return $card;
}

sub task_for {
    my ( $text, $ref, $status ) = @_;
    # refs, plural - the engine's own key. Written as `ref` first, which stored
    # an empty list silently and made the rule look broken when the fixture was
    # what had failed. tasklist_add takes `$args{refs} // []`, so a wrong name
    # is not refused, it is defaulted.
    my $t = $tira->tasklist_add( project => $root, text => $text, refs => [$ref] );
    $tira->tasklist_update( project => $root, id => $t->{id}, status => $status )
      if defined $status;
    return $t->{id};
}

# --- the rule exists and takes its columns ----------------------------------
#
# Declared the way card-duration and wip-limit are, because the board cannot
# work out for itself which columns mean somebody is working.

my $undeclared = do {
    local $@;
    eval { $tira->policy_add(
        project => $root, rule => 'task-card-mismatch', action => 'bridge-reminder' ); };
    $@;
};
# Passes today for the WRONG reason and is flagged rather than counted: the
# rule does not exist, so policy_add refuses it as an unknown rule, not as one
# missing its column. It only starts meaning what it says once assertion 3 is
# green - which is why the pair is written together and why the message is
# asserted separately below.
isnt( $undeclared, '',
    'the rule refuses to be declared without saying which columns mean work' );
like( $undeclared, qr/--column/,
    'and the refusal names the option, as every other refusal here does' );

my $declared = do {
    local $@;
    eval { $tira->policy_add(
        project => $root, rule => 'task-card-mismatch',
        column => 'implement', action => 'bridge-reminder' ); };
    $@;
};
is( $declared, '', 'and is declarable against a column that does mean work' );

# And refuses --age, which is the ledger t/79 keeps: a rule that declares an
# option it will not honour has to have a test handing it that option, or the
# forbids entry is a claim nobody checked. The reason is not bookkeeping -
# board-still and task-unlinked give a grace because a board might legitimately
# be quiet for a while, and a contradiction has no equivalent. A task saying
# working about a card in backlog was wrong when it was written and no amount
# of waiting makes it righter.
my $aged = do {
    local $@;
    eval { $tira->policy_add(
        project => $root, rule => 'task-card-mismatch',
        column => 'implement', age => '30m', action => 'bridge-reminder' ); };
    $@;
};
like( $aged, qr/age/,
    'and refuses --age - a contradiction is wrong the moment it exists, not after a grace' );

# --- the fixture: four tasks, three of them honest --------------------------

my $queued     = card_in( 'queued card',     'next-to-work-on' );
my $working    = card_in( 'card being worked', 'implement' );
my $finished   = card_in( 'finished card',   'done' );

my $honest_queued  = task_for( 'a task for the queued card',   $queued->{ref},   'pending' );
my $honest_working = task_for( 'a task for the worked card',   $working->{ref},  'working' );
my $honest_done    = task_for( 'a task for the finished card', $finished->{ref}, 'done' );
my $liar           = task_for( 'a task left pending',          $working->{ref},  'pending' );

sub findings {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'task-card-mismatch' }
        @{ $pass->{violations} // [] } ];
}

my $found = findings();
my %about = map { ( $_->{ref} // '' ) => $_ } @{$found};

# --- what it must report ----------------------------------------------------

is( scalar @{$found}, 1,
    'exactly one mismatch is reported, out of four tasks' );
ok( exists $about{$liar},
    'and it is the task left pending while its card is being worked' );

# --- and what it must NOT ---------------------------------------------------
#
# The three controls, and the first is the one the reference script fails. A
# rule that reported it would be right about the arithmetic and wrong about the
# board, and would bury its own real findings in noise - measured, seven false
# lines in eight, every thirty minutes.

ok( !exists $about{$honest_queued},
    'a pending task whose card is merely QUEUED is not a mismatch - nobody has started it' );
ok( !exists $about{$honest_working},
    'a working task whose card is being worked is not a mismatch' );
ok( !exists $about{$honest_done},
    'and a done task whose card is done is not a mismatch' );

# --- the direction the owner named ------------------------------------------
#
# "which tasks say working while the card they name sits in backlog" - his
# words, and the case he cared about most. It is the opposite direction from
# the one above and needs its own fixture.

my $idle = card_in( 'a card nobody has started', 'backlog' );
my $eager = task_for( 'a task that got ahead of itself', $idle->{ref}, 'working' );

# No second policy here, and the reason is worth keeping. The first version of
# this file declared another task-card-mismatch with column => 'backlog', which
# under the engine's ordinary reading of --column as a SCOPE made backlog a
# second, separate opinion about what work means - and every working task on an
# implement card was then reported by the backlog policy while the implement
# policy reported the reverse. Two assertions below went green for entirely the
# wrong reason before I noticed.
#
# That is fixed at the root now: policies of this rule compose into one set
# rather than contradicting, asserted further down with both spellings. The
# fixture keeps a single policy anyway, because the case here is about backlog
# NOT being work, and declaring it would say the opposite.
#
# So this case needs nothing new: backlog is not in the declared set, and a
# task saying working about a card there is the mismatch the owner named.

my %now = map { ( $_->{ref} // '' ) => $_ } @{ findings() };
ok( exists $now{$eager},
    'a task saying working while its card sits in backlog is reported - the case he named' );

# --- a card carrying two tasks that say the same thing ----------------------
#
# The third of the owner's three parts, and the reference script is stricter
# about it than the card was - deliberately, and its comment is the whole rule:
#
#   Multiplicity alone is NOT a fault: an incoming message, a follow-up
#   question and a scope change legitimately name one card. Only near-identical
#   text does.
#
# So this is not "a card with more than one task". Two tasks about one card is
# ordinary and reporting it would make the rule noise. What is worth saying is
# that somebody has written the same note twice and will now tick one and
# wonder why the other is still open.

# The comparison is the first sixty characters, which is the script's test, so
# the fixture has to be written to sixty characters or it tests nothing. The
# first attempt used two texts of 48 and 57 characters that differed at the
# end; truncation did nothing to either, they were simply two different
# strings, and the assertion was red for a reason that had nothing to do with
# the rule. Both of these share their opening clause and diverge after it.
my $twice = card_in( 'a card written up twice', 'implement' );
my $first  = task_for(
    'Port the reference script into the police routine so the bridge reports it',
    $twice->{ref}, 'working' );
my $second = task_for(
    'Port the reference script into the police routine so the bridge reports it, in Perl',
    $twice->{ref}, 'working' );

# And the control, on the same card: a genuinely different note about the same
# work. This is the one the script's comment is defending, and a rule that
# reported it would be reporting ordinary bookkeeping as a fault.
my $different = task_for(
    'Ask the owner which columns count as working before porting anything',
    $twice->{ref}, 'working' );

my %dup = map { ( $_->{ref} // '' ) => $_ } @{ findings() };

ok( exists $dup{$second},
    'two tasks whose text is near-identical about one card are reported' );
ok( !exists $dup{$different},
    'while a genuinely different note about the same card is not - several tasks may name one card' );
ok( !exists $dup{$first},
    'and the pair is reported once rather than twice, against the later of the two' );

# And the pair nobody needs telling about. The complaint is that one gets
# ticked and the other lingers; when both are already ticked there is nothing
# left to linger, and reporting it would be the rule talking to itself.
my $shut = card_in( 'a card whose duplicate pair is finished', 'implement' );
task_for( 'Wire the duplicate check into the police pass and prove it in Docker',
    $shut->{ref}, 'done' );
my $second_done = task_for(
    'Wire the duplicate check into the police pass and prove it in Docker, twice',
    $shut->{ref}, 'done' );

my %quiet = map { ( $_->{ref} // '' ) => $_ } @{ findings() };
ok( !exists $quiet{$second_done},
    'a duplicate pair that is entirely done is left alone - nothing is waiting to be ticked' );

# --- one task says its most important thing once ----------------------------
#
# The violation ledger keys an entry by (rule, policy, ref), so two findings
# about one task under one policy ARE one entry - same VIO number, same
# first_seen, same seen count, and the quiet ladder lets only the first speak
# per pass. Found by walking the six test_steps through the real CLI rather
# than by reading: a task both left working on a backlogged card and written
# twice produced VIO-0003 twice in a single pass, the second marked quiet. The
# bridge line for that number would then describe whichever finding spoke while
# its "seen N times" claimed one continuous history.

my $backlogged = card_in( 'a card written up twice and not started', 'backlog' );
my $shouting = task_for(
    'Port the reference script into the police routine so the bridge reports it',
    $backlogged->{ref}, 'working' );
my $shouting_too = task_for(
    'Port the reference script into the police routine so the bridge reports it, again',
    $backlogged->{ref}, 'working' );

my @both = grep { ( $_->{ref} // '' ) eq $shouting_too } @{ findings() };
is( scalar @both, 1,
    'a task with both a status mismatch and a duplicate is reported once, not twice - the ledger keys on rule+policy+ref and cannot hold two' );
like( $both[0]{detail} // $both[0]{message} // '', qr/says working/,
    'and the one it says is the status mismatch, which is what the card was raised for' );

# And the duplicate is not lost, only queued behind the louder finding - said
# as soon as the status is put right, which is the order somebody would fix
# them in anyway.
$tira->tasklist_update( project => $root, id => $shouting_too, status => 'pending' );
my @after_fix = grep { ( $_->{ref} // '' ) eq $shouting_too } @{ findings() };
is( scalar @after_fix, 1, 'and once the status is put right it still has exactly one finding' );
like( $after_fix[0]{detail} // $after_fix[0]{message} // '', qr/says almost/,
    'which is now the duplicate - queued behind the status mismatch rather than dropped' );

# One task, two cards, a duplicate on each: still one finding. The status loop
# marks a task said and so does this one, because two duplicate findings about
# one task collide in the ledger exactly as a status mismatch and a duplicate
# do - the same defect, reached by a different route.
my $left  = card_in( 'one of two cards a task names', 'implement' );
my $right = card_in( 'the other card that task names', 'implement' );
my $twinned = sub {
    my ($text) = @_;
    my $t = $tira->tasklist_add(
        project => $root, text => $text, refs => [ $left->{ref}, $right->{ref} ] );
    $tira->tasklist_update( project => $root, id => $t->{id}, status => 'working' );
    return $t->{id};
};
$twinned->('Check the police store for a frozen last_pass and report what it says');
my $twin_second = $twinned->('Check the police store for a frozen last_pass and report what it found');
my @twins = grep { ( $_->{ref} // '' ) eq $twin_second } @{ findings() };
is( scalar @twins, 1,
    'a task duplicated on two different cards at once is still reported once - two duplicate findings collide in the ledger just as a status mismatch and a duplicate do' );

# --- the third direction: a card that finished without its task -------------
#
# solution_needed's own third case, "an unfinished task on a card in done". It
# is not the same as the first: pending against a BACKLOG card is the board
# telling the truth, and pending against a card that shipped is a task nobody
# closed. The difference is that done is PAST the work and backlog is before
# it, which the board already knows from the order it declares its columns in -
# so the rule reads that rather than asking for a second option.

my $shipped = card_in( 'a card that finished without its task', 'done' );
my $forgotten = task_for( 'Close this when the card lands', $shipped->{ref}, 'pending' );

my %after = map { ( $_->{ref} // '' ) => $_ } @{ findings() };
ok( exists $after{$forgotten},
    'a pending task whose card has reached done is reported - the card finished without it' );
like( $after{$forgotten}{detail} // $after{$forgotten}{message} // '', qr/never closed/,
    'and it is told apart from the other two directions, which are about disagreement rather than a loose end' );

# The control that makes the assertion above mean something, and it is
# assertion 6 again from the other side: pending against a card BEFORE the work
# columns stays silent. Without this pair, "not done and not a work column"
# would look like a working rule while reporting every queued card on the board.
ok( !exists $after{$honest_queued},
    'while a pending task whose card has not got there yet is still silent' );

# --- the push question, which acceptance_criteria asks to settle -----------
#
# "A task saying working whose card is in push or install is NOT reported, or
# the rule says why it is." Settled by the design rather than by a special
# case: a board that considers push part of the work declares push among its
# --column values, and then a working task there is ordinary. This board's
# declared set stops at implement, so push is past it - and the finding says
# exactly that rather than accusing the queue of disagreeing with the board.
#
# It is the case the hand-run measurement found most of: five of its seven
# mismatches were tasks still saying working after their cards had moved to
# push, and they were real. The work was finished and the notes were not.

my $shipping = card_in( 'a card in the middle of being released', 'push' );
my $still_open = task_for( 'Run the release and watch it land', $shipping->{ref}, 'working' );

my %released = map { ( $_->{ref} // '' ) => $_ } @{ findings() };
ok( exists $released{$still_open},
    'a working task whose card has reached push is reported - five of the seven measured mismatches were this' );
like( $released{$still_open}{detail} // $released{$still_open}{message} // '', qr/reached push/,
    'and it says why, naming the column the card got to - which is what acceptance asked for if it reported at all' );

# The other half of the same decision, and the reason no special case is
# needed: declare push as work and the same task is ordinary.
#
# Declared as TWO policies deliberately, because that is the shape that used to
# break. A policy's --column is a scope everywhere else in the engine - "the
# same rule watching a different column is a different intention" - and read
# that way, one policy per working column made each policy report the others'
# honest tasks. For this rule the columns are one set, so they compose; two
# policies here must behave exactly as the comma-separated single policy
# asserted below, and both must be silent about this task.
my $other = File::Spec->catdir( $tmp, 'push-is-work' );
$tira->project_new(
    name => 'Push counts as work', dir => $other, members => ['claude'],
    columns => ['backlog, implement, push, done'],
    sow_prefix => 'PSW', epic_prefix => 'PEP', ticket_prefix => 'PTK',
);
$tira->policy_add( project => $other, rule => 'task-card-mismatch',
    column => 'implement', action => 'bridge-reminder' );
$tira->policy_add( project => $other, rule => 'task-card-mismatch',
    column => 'push', action => 'bridge-reminder' );
my $their_card = $tira->create_record(
    project => $other, author => 'claude', type => 'ticket', title => 'a card being released' );
$tira->record_move(
    project => $other, author => 'claude', ref => $their_card->{ref}, column => 'push' );
my $their_task = $tira->tasklist_add(
    project => $other, text => 'Run the release and watch it land', refs => [ $their_card->{ref} ] );
$tira->tasklist_update( project => $other, id => $their_task->{id}, status => 'working' );

my $their_pass = $tira->police_pass(
    project => $other, store => File::Spec->catdir( $tmp, 'push-store' ), world => {} );
my @theirs = grep { ( $_->{rule} // '' ) eq 'task-card-mismatch' }
  @{ $their_pass->{violations} // [] };
is( scalar @theirs, 0,
    'while a board that declares push as work is not told anything about the same task - the option settles it, not a built-in exemption' );

# And the same set written the other way. project.new already takes its columns
# as one comma-separated string, so a policy naming several reads the same way,
# and the two forms have to agree or the choice between them becomes a trap.
my $listed = File::Spec->catdir( $tmp, 'push-is-work-listed' );
$tira->project_new(
    name => 'Push counts as work, said once', dir => $listed, members => ['claude'],
    columns => ['backlog, implement, push, done'],
    sow_prefix => 'LSW', epic_prefix => 'LEP', ticket_prefix => 'LTK',
);
$tira->policy_add( project => $listed, rule => 'task-card-mismatch',
    column => 'implement, push', action => 'bridge-reminder' );
my $listed_card = $tira->create_record(
    project => $listed, author => 'claude', type => 'ticket', title => 'a card being released' );
$tira->record_move(
    project => $listed, author => 'claude', ref => $listed_card->{ref}, column => 'push' );
my $listed_task = $tira->tasklist_add(
    project => $listed, text => 'Run the release and watch it land', refs => [ $listed_card->{ref} ] );
$tira->tasklist_update( project => $listed, id => $listed_task->{id}, status => 'working' );

my $listed_pass = $tira->police_pass(
    project => $listed, store => File::Spec->catdir( $tmp, 'listed-store' ), world => {} );
my @listed_found = grep { ( $_->{rule} // '' ) eq 'task-card-mismatch' }
  @{ $listed_pass->{violations} // [] };
is( scalar @listed_found, 0,
    'and one policy naming both columns in a comma-separated list says exactly the same thing as two policies' );

# The control that stops the pair above passing vacuously. If the rule had
# simply stopped reporting, both would be green and neither would mean
# anything. A card in a column NEITHER policy names is still reported on that
# same board.
my $stray = $tira->create_record(
    project => $listed, author => 'claude', type => 'ticket', title => 'a card nobody has started' );
my $stray_task = $tira->tasklist_add(
    project => $listed, text => 'a task that got ahead of itself', refs => [ $stray->{ref} ] );
$tira->tasklist_update( project => $listed, id => $stray_task->{id}, status => 'working' );
my $stray_pass = $tira->police_pass(
    project => $listed, store => File::Spec->catdir( $tmp, 'listed-store' ), world => {} );
my @stray_found = grep { ( $_->{rule} // '' ) eq 'task-card-mismatch' }
  @{ $stray_pass->{violations} // [] };
is( scalar @stray_found, 1,
    'while that same board is still told about a working task whose card is in backlog - the two silences above are the rule agreeing, not the rule switched off' );

# --- declared by role, which policy_add already allows ----------------------
#
# key_details asks a question outright: "whether the working-column set should
# come from column roles rather than being hard-coded". The answer is that
# policy_add settled it before this rule existed - its needs check accepts a
# --column-role wherever a --column is required - so a board CAN declare this
# rule by role whether or not the rule reads one, and a rule that ignored roles
# would compute an empty working set from a declaration the engine accepted
# without complaint.
#
# An empty set is not a quiet failure. It calls every working task a mismatch
# and every genuine pending-on-work case honest - exactly inverted - which is
# why both halves are asserted here rather than one.

my $by_role = File::Spec->catdir( $tmp, 'work-by-role' );
$tira->project_new(
    name => 'Work named by role', dir => $by_role, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'RSW', epic_prefix => 'REP', ticket_prefix => 'RTK',
);
$tira->column_roles_set(
    project => $by_role, type => 'ticket', roles => { work => 'implement' } );
$tira->policy_add( project => $by_role, rule => 'task-card-mismatch',
    column_role => 'work', action => 'bridge-reminder' );

my $role_card = $tira->create_record(
    project => $by_role, author => 'claude', type => 'ticket', title => 'a card being worked' );
$tira->record_move(
    project => $by_role, author => 'claude', ref => $role_card->{ref}, column => 'implement' );
my $honest = $tira->tasklist_add(
    project => $by_role, text => 'a task for the worked card', refs => [ $role_card->{ref} ] );
$tira->tasklist_update( project => $by_role, id => $honest->{id}, status => 'working' );
my $lagging = $tira->tasklist_add(
    project => $by_role, text => 'a task left pending', refs => [ $role_card->{ref} ] );

my $role_pass = $tira->police_pass(
    project => $by_role, store => File::Spec->catdir( $tmp, 'role-store' ), world => {} );
my %by_role_found = map { ( $_->{ref} // '' ) => $_ }
  grep { ( $_->{rule} // '' ) eq 'task-card-mismatch' } @{ $role_pass->{violations} // [] };

ok( !exists $by_role_found{ $honest->{id} },
    'a policy declared with --column-role resolves the role to its column - the working task is left alone' );
ok( exists $by_role_found{ $lagging->{id} },
    'and the pending task on that same card is still reported, so the role resolved to something rather than to nothing' );

# --- three things a code review found, and none of them by reading ----------
#
# All three came from an adversarial pass over the finished rule. Two were
# reachable through the CLI and one would have taken the whole police pass
# down. They are asserted here rather than merely fixed, because each is the
# kind of input nobody writes on purpose and everybody eventually writes.

# ONE: a task carrying the same ref twice. tasklist_task_ref_link dedupes -
# it keeps a %have - but tasklist_add stores refs as given and --ref is
# repeatable, so this is storable today. The duplicate walk met the item again
# on its second turn through the same ref and reported it as duplicating
# ITSELF, naming its own id back at it.
my $twice_linked = $tira->tasklist_add(
    project => $root, text => 'Check the store, then check it again',
    refs => [ $working->{ref}, $working->{ref} ] );
$tira->tasklist_update(
    project => $root, id => $twice_linked->{id}, status => 'working' );
my @self_dup = grep { ( $_->{ref} // '' ) eq $twice_linked->{id} } @{ findings() };
is( scalar @self_dup, 0,
    'a task that names the same card twice is not reported as a duplicate of itself' );

# TWO: the duplicate walk did not keep the silence the status walk keeps. A
# ref naming no card is task-unlinked's business at most, and two tasks
# sharing an opening clause about a card that does not exist were reported as
# duplicates - a complaint about bookkeeping on a card nobody can open.
# Sixty characters, checked rather than assumed. The first version of this
# fixture used two texts of 59 and 68 characters that diverged at the comma -
# so their first-sixty keys differed, they were never a duplicate pair, and the
# assertion passed against the UNFIXED code. That is the same fixture mistake
# this file already records once, made again on the assertion written to catch
# somebody else's bug. Both of these share their first sixty characters:
# 'Write up in full what the missing card was supposed to have '.
for my $text ( 'Write up in full what the missing card was supposed to have covered, and why',
               'Write up in full what the missing card was supposed to have covered, and when' ) {
    my $t = $tira->tasklist_add( project => $root, text => $text, refs => ['QTK-404'] );
    $tira->tasklist_update( project => $root, id => $t->{id}, status => 'working' );
}
my @phantom = grep { ( $_->{detail} // $_->{message} // '' ) =~ /QTK-404/ } @{ findings() };
is( scalar @phantom, 0,
    'and two near-identical tasks about a ref that names no card are not reported - that silence is kept in both walks, not one' );

# THREE: the column-order build dereferenced column_list without a guard, so a
# board that cannot answer for one record type lost EVERY finding in that pass.
# police_pass wraps policy_evaluate in an eval and sets $found = [] when it
# throws - "police guessing is worse than police silent" - so the process does
# not die and nothing crashes. It just goes quiet, for every rule at once.
#
# So the assertion is not that the pass survives. It survives either way, which
# is exactly what made the first version of this assertion pass against the
# unguarded code. The assertion is that the findings survive.
{
    no warnings 'redefine';
    my $real = \&Tira::column_list;
    local *Tira::column_list = sub {
        my ( $self, %args ) = @_;
        die "no board for $args{type}\n" if ( $args{type} // '' ) eq 'sow';
        return $real->( $self, %args );
    };
    ok( scalar @{ findings() },
        'a board that cannot answer column_list for one record type still gets its findings - the guard keeps the whole pass from going silent' );
}

# --- and it sees the whole queue, not one session ---------------------------
#
# test_steps' last line. The tasklist is one file for the project with a
# session recorded per item, so a rule reading it reads every session by
# construction - but tasklist_list defaults to filtering by session, and a
# rule built on that instead would have quietly checked only its own.

my $elsewhere = $tira->tasklist_add(
    project => $root, session => 'some-other-session',
    text => 'a task somebody else wrote', refs => [ $idle->{ref} ] );
# The session has to be named again to update it - tasklist_update scopes to
# the caller's session and answers "No task 'TSK-012'" otherwise, which is
# exactly the scoping this assertion exists to prove the RULE does not inherit.
$tira->tasklist_update(
    project => $root, session => 'some-other-session',
    id => $elsewhere->{id}, status => 'working' );

my %across = map { ( $_->{ref} // '' ) => $_ } @{ findings() };
ok( exists $across{ $elsewhere->{id} },
    'a mismatch recorded in another session is reported too - the rule reads the queue, not its own corner of it' );

done_testing();

__END__

=head1 NAME

t/419-a-queue-that-disagrees-with-the-board.t - police must notice when a task's
status contradicts the column its card is in

=head1 DESCRIPTION

C<task-unlinked> catches a task with no card. Nothing catches a task whose
status contradicts the card it names, so the queue and the board can disagree
and only a person reading both notices. Measured by hand across 51 tasks and 47
cards: seven mismatches, including five tasks left saying working after their
cards moved to push.

The column set is the design. The owner's own reference script names
C<next-to-work-on> among its working columns, and that one line produces seven
false reports in eight - a card there is QUEUED, and a task saying pending
about it is the board being truthful. The board cannot infer the distinction:
C<backlog> and C<discard> are protected and C<next-to-work-on> is not, so "not
protected" sweeps it back in. Which columns mean somebody is working is a
statement about how a board is run, so the rule takes them, as C<card-duration>
and C<wip-limit> already do.

The three controls matter as much as the finding. A rule that reported a queued
card's pending task would be arithmetically right, wrong about the board, and
would bury its real findings in its own noise.

It reports and does nothing else, which is C<scope_excluded>'s first line and
the owner's own instruction.

=cut
