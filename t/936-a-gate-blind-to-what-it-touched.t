#!/usr/bin/env perl

# TKT-936, TKT-799's own gap: docs/commands.md once claimed a conditional
# required action fired on the verify column when a card's changes touched
# lib/Tira/views/*, DashboardWeb.pm or OnboardWeb.pm - prompting
# tools/browser-tests before the card could leave. It was never built;
# verify's required_actions carried no such item at all, so every card left
# verify blind to whether it had touched a browser-relevant file.
#
# Michael's answer to Q-154: Option A - a NEW required-action kind, evaluated
# at move-time by reading the card's own git diff, not a police rule.
#
# This board has no per-card git branch to diff against (TKT-902/commit-msg's
# own gate reads the one shared branch's staged/HEAD state, not a per-card
# one) - the only place "what did this card touch" can be answered from is
# real git history, grepped by the card's own ref in the commit subject, the
# same way every Changes entry and commit this project makes already names
# its card. So a required-action template entry can now be a hash
# { text => ..., touches => [PATTERN, ...] } instead of a plain string: at
# move-time, _record_touched_paths reads every commit's hash and subject
# line, keeps only the ones whose subject names this card's ref as an EXACT
# ref-shaped token (not a substring - `git log --grep` alone would let TKT-9
# match a commit actually about TKT-90, and would match a passing mention in
# a commit's body too), and reads only those matching commits' changed paths
# (`git log --no-walk --name-only`, given the matching hashes directly). The
# item is only placed on the card if one of those paths matches one of its
# patterns. A bare pattern (no '/') matches by basename anywhere in the tree;
# a pattern with '/' and a trailing '*' matches by prefix. A plain string
# item is unaffected - it is placed unconditionally, exactly as before.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new( clock => sub { '2026-09-10T11:00:00+0100' } );
$tira->project_new(
    name => 'Touched or not', dir => $root, members => ['ada'],
    columns => ['backlog, verify, pending-push'],
    sow_prefix => 'TSW', epic_prefix => 'TEP', ticket_prefix => 'TTK',
);

# The board root doubles as the git repo _record_touched_paths reads - real
# practice on this project: .tira/ lives inside the same repo whose commits
# it greps (see MISTAKE.md/memory: "tira repo-root .tira/ is the production
# board"). A tempdir board needs its own repo for this to have anything to
# read.
system( 'git', '-C', $root, 'init', '--quiet' ) == 0 or BAIL_OUT('git init failed');
system( 'git', '-C', $root, 'config', 'user.email', 'test@example.com' ) == 0 or BAIL_OUT('git config failed');
system( 'git', '-C', $root, 'config', 'user.name',  'Test' ) == 0            or BAIL_OUT('git config failed');

$tira->column_update(
    project => $root, type => 'ticket', name => 'verify',
    required_action => [
        'Always owed: full suite green',
        {
            text    => 'Run tools/browser-tests before this card can leave verify',
            touches => [ 'lib/Tira/views/*', 'DashboardWeb.pm', 'OnboardWeb.pm' ],
        },
    ],
);

sub run_cli {
    my ( $command, @argv ) = @_;
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;

    # A general-purpose capture rather than a refusal assertion: any failure is what this means.
    # The assertions that read it check a specific message on $out/$err instead, for the refusal each is about.
    my $died = !eval {
        Tira::CLI->run( command => $command, tira => $tira,
            argv => [ '--type', 'ticket', @argv, '-o', 'toon' ] );
        1;
    };
    my $why = $@;
    select $old;
    return { out => $stdout // '', err => $said // '', died => $died, why => $why };
}

sub items_on {
    my ($ref) = @_;
    my $record = eval { $tira->record_show( project => $root, type => 'ticket', ref => $ref ) }
      or return [];
    return $record->{required_items} // [];
}

sub named {
    my ( $ref, $wanted ) = @_;
    return grep { ( $_->{item} // '' ) eq $wanted } @{ items_on($ref) };
}

sub commit_touching {
    my ( $ref, @files ) = @_;
    for my $rel (@files) {
        my $path = File::Spec->catfile( $root, $rel );
        require File::Basename;
        my $dir = File::Basename::dirname($path);
        system( 'mkdir', '-p', $dir ) == 0 or BAIL_OUT("mkdir $dir failed");
        open my $fh, '>', $path or BAIL_OUT("write $path failed");
        print {$fh} "touched by $ref\n";
        close $fh;
    }
    system( 'git', '-C', $root, 'add', '-A' ) == 0 or BAIL_OUT('git add failed');
    system( 'git', '-C', $root, 'commit', '--quiet', '-m', "$ref: a change" ) == 0
      or BAIL_OUT('git commit failed');
    return;
}

my $BROWSER_ITEM = 'Run tools/browser-tests before this card can leave verify';

# --- a card whose commit touches a view file -------------------------------

my $view_card = $tira->create_record(
    project => $root, author => 'ada', type => 'ticket', title => 'touches a view file' );
commit_touching( $view_card->{ref}, 'lib/Tira/views/dashboard.css' );
run_cli( 'record.move', '--ref', $view_card->{ref}, '--column', 'verify', '--author', 'ada' );

ok( scalar named( $view_card->{ref}, $BROWSER_ITEM ),
    'a card whose commit touched lib/Tira/views/* is given the browser-test item on entering verify' );
ok( scalar named( $view_card->{ref}, 'Always owed: full suite green' ),
    'the plain, unconditional item is placed too - the new kind does not crowd out the old' );

my $leave_view = run_cli( 'record.move', '--ref', $view_card->{ref}, '--column', 'pending-push', '--author', 'ada' );
like( $leave_view->{out} . $leave_view->{err}, qr/Cannot move \S+ out of verify/,
    'and the card cannot leave verify until it is done - the gate the doc originally claimed' );
like( $leave_view->{out} . $leave_view->{err}, qr/\Q$BROWSER_ITEM\E/,
    'named in the refusal, same as any other required action' );

# --- a card whose commit does not touch a browser-relevant path -----------

my $plain_card = $tira->create_record(
    project => $root, author => 'ada', type => 'ticket', title => 'touches only the engine' );
commit_touching( $plain_card->{ref}, 'lib/Tira.pm' );
run_cli( 'record.move', '--ref', $plain_card->{ref}, '--column', 'verify', '--author', 'ada' );

is( scalar named( $plain_card->{ref}, $BROWSER_ITEM ), 0,
    'a card whose commit touched only lib/Tira.pm is NOT given the browser-test item - unaffected, as the acceptance criteria says' );
ok( scalar named( $plain_card->{ref}, 'Always owed: full suite green' ),
    'the unconditional item is still placed on it' );

my ( $req_id ) = map { $_->{id} } grep { ( $_->{item} // '' ) eq 'Always owed: full suite green' }
  @{ items_on( $plain_card->{ref} ) };
$tira->required_item_update( project => $root, type => 'ticket', ref => $plain_card->{ref},
    id => $req_id, status => 'done', author => 'ada', command => ['n/a'], proof => ['n/a'] );
my $leave_plain = run_cli( 'record.move', '--ref', $plain_card->{ref}, '--column', 'pending-push', '--author', 'ada' );
ok( !$leave_plain->{died} && $leave_plain->{out} !~ /Cannot move/,
    'and it can leave verify freely once its own (unconditional) item is done - never blocked on a gate it never touched' );

# --- the bare-filename half of the pattern language, and a full path -------

my $dashboard_card = $tira->create_record(
    project => $root, author => 'ada', type => 'ticket', title => 'touches DashboardWeb.pm' );
commit_touching( $dashboard_card->{ref}, 'lib/Tira/DashboardWeb.pm' );
run_cli( 'record.move', '--ref', $dashboard_card->{ref}, '--column', 'verify', '--author', 'ada' );

ok( scalar named( $dashboard_card->{ref}, $BROWSER_ITEM ),
    'a bare pattern (DashboardWeb.pm, no slash) matches the file anywhere in the tree, not only at the repo root' );

# --- a ref match is exact, not a substring of a longer one ------------------
#
# git --grep is a substring match against the whole commit message - a naive
# --grep=$ref would let a short ref's commits leak into a longer ref sharing
# its prefix (TTK-1 matching a commit actually about TTK-10), and would also
# match a passing mention in a commit's BODY, not only its subject.

my $short_card = $tira->create_record(
    project => $root, author => 'ada', type => 'ticket', title => 'a ref that is a prefix of another' );
my $longer_card = $tira->create_record(
    project => $root, author => 'ada', type => 'ticket', title => 'a ref the short one is a prefix of' );
# Constructed so $short_card->{ref} is a proper string prefix of $longer_card->{ref}'s numeric part - TTK-NNN vs TTK-NNN0, say.
commit_touching( $longer_card->{ref} . '0', 'lib/Tira/views/should-not-count.css' );
run_cli( 'record.move', '--ref', $short_card->{ref}, '--column', 'verify', '--author', 'ada' );
is( scalar named( $short_card->{ref}, $BROWSER_ITEM ), 0,
    "a commit naming $short_card->{ref}0 does not count as touching $short_card->{ref} - refs match exactly, not as a substring" );

# --- a plain string item stays plain - the mechanism is additive ----------

$tira->column_update(
    project => $root, type => 'ticket', name => 'backlog',
    required_action => ['A plain, unconditional string item'],
);
my $control_result = run_cli( 'record.create', '--title', 'never leaves backlog in this test', '--author', 'ada' );
my ($control_ref) = ( $control_result->{out} // '' ) =~ /(TTK-\d+)/;
ok( scalar named( $control_ref, 'A plain, unconditional string item' ),
    'a column whose required_actions are all plain strings behaves exactly as before' );

# --- validation: a broken conditional item is refused the same way --------

my $bad_touches = eval {
    $tira->column_update(
        project => $root, type => 'ticket', name => 'verify',
        required_action => [ { text => 'Missing its touches list' } ],
    );
    1;
};
ok( !$bad_touches, 'a conditional item declared without a touches list is refused' );
like( $@, qr/touches/i, 'naming what is missing' );

my $bad_empty_text = eval {
    $tira->column_update(
        project => $root, type => 'ticket', name => 'verify',
        required_action => [ { text => '', touches => ['x'] } ],
    );
    1;
};
ok( !$bad_empty_text, 'a conditional item with empty text is refused, same as a plain empty string is' );

# --- the CLI parses "PATTERN,...=TEXT", refusing a malformed pattern list --

my $malformed = run_cli( 'column.update', '--name', 'backlog',
    '--required-action-if-touches', 'a,,b=TEXT with a doubled comma' );
like( $malformed->{out} . $malformed->{err}, qr/blank pattern/i,
    'refused for the blank pattern a doubled comma leaves - not silently dropped down to two real patterns' );

my $no_equals = run_cli( 'column.update', '--name', 'backlog',
    '--required-action-if-touches', 'lib/Tira/views/* no equals sign at all' );
like( $no_equals->{out} . $no_equals->{err}, qr/no '='/,
    'refused when the spec carries no "=" separator at all' );

my $all_blank = run_cli( 'column.update', '--name', 'backlog',
    '--required-action-if-touches', '=Only text, no pattern before the equals' );
like( $all_blank->{out} . $all_blank->{err}, qr/needs at least one pattern/i,
    'refused when the patterns half is entirely empty, distinct from a doubled-comma partial blank' );

# --- the CLI flag's own success path, end to end -----------------------

$tira->column_add( project => $root, type => 'ticket', name => 'flag-built', after => 'backlog' );
run_cli( 'column.update', '--name', 'flag-built',
    '--required-action-if-touches', 'lib/Tira/views/*,DashboardWeb.pm=Run tools/browser-tests' );
my ($flag_built_col) = grep { $_->{name} eq 'flag-built' }
  @{ $tira->column_list( project => $root, type => 'ticket' ) };
my ($flag_built_item) = grep { ref $_ eq 'HASH' } @{ $flag_built_col->{required_actions} // [] };
ok( $flag_built_item, '--required-action-if-touches actually stores a conditional item, not just validates one built by hand' );
is( $flag_built_item->{text}, 'Run tools/browser-tests', 'with the text half after the first "="' ) if $flag_built_item;
is_deeply( $flag_built_item->{touches}, [ 'lib/Tira/views/*', 'DashboardWeb.pm' ], 'and the comma-split patterns before it' )
  if $flag_built_item;

# --- a conditional ENTRY required action - the mirror of the exit-side tests above --

$tira->column_add( project => $root, type => 'ticket', name => 'gated-entry', after => 'backlog' );
$tira->column_update(
    project => $root, type => 'ticket', name => 'gated-entry',
    entry_required_action => [ { text => 'Prove the browser change first', touches => ['lib/Tira/views/*'] } ],
);

my $entry_match_card = $tira->create_record(
    project => $root, author => 'ada', type => 'ticket', title => 'entry gate: touches a view file' );
commit_touching( $entry_match_card->{ref}, 'lib/Tira/views/entry-gate.css' );
my $entry_move_1 = run_cli( 'record.move', '--ref', $entry_match_card->{ref}, '--column', 'gated-entry', '--author', 'ada' );
like( $entry_move_1->{out} . $entry_move_1->{err}, qr/Prove the browser change first/,
    'a matching conditional ENTRY action blocks the move in, same as an exit one blocks the move out' );

my $entry_nomatch_card = $tira->create_record(
    project => $root, author => 'ada', type => 'ticket', title => 'entry gate: touches only the engine' );
commit_touching( $entry_nomatch_card->{ref}, 'lib/Tira.pm' );
my $entry_move_2 = run_cli( 'record.move', '--ref', $entry_nomatch_card->{ref}, '--column', 'gated-entry', '--author', 'ada' );
ok( !$entry_move_2->{died} && $entry_move_2->{out} !~ /Cannot move/,
    'a non-matching conditional ENTRY action never appears - the card moves in freely' );

# A manually-added item sharing the conditional entry's TEXT, on a card whose
# own commits do NOT match - must not be read as satisfying a live
# obligation the card was never actually given (the %wanted fix).
my $decoy_card = $tira->create_record(
    project => $root, author => 'ada', type => 'ticket', title => 'entry gate: a decoy manual item' );
commit_touching( $decoy_card->{ref}, 'lib/Tira.pm' );
$tira->required_item_add( project => $root, type => 'ticket', ref => $decoy_card->{ref}, author => 'ada',
    item => 'Prove the browser change first', status => 'pending', column => 'gated-entry', source => 'manual' );
my $entry_move_3 = run_cli( 'record.move', '--ref', $decoy_card->{ref}, '--column', 'gated-entry', '--author', 'ada' );
ok( !$entry_move_3->{died} && $entry_move_3->{out} !~ /Cannot move/,
    'a manually-added item sharing the unmatched conditional text does not block the move either - it is not a live obligation for this card' );

# --- a column whose required_actions are ALL conditional never demands --author at create -----
#
# The author-required-for-a-gated-column preflight used to look only at
# whether required_actions was non-empty - so a column carrying nothing but
# a conditional item refused an author-less create even though that item can
# never be placed at create time (its ref cannot be in any commit before the
# card exists) and required_item_add, the actual reason an author is needed,
# was never going to run.

$tira->column_add( project => $root, type => 'ticket', name => 'gated-only-conditional', after => 'backlog' );
$tira->column_update(
    project => $root, type => 'ticket', name => 'gated-only-conditional',
    required_action => [ { text => 'Only ever conditional', touches => ['lib/Tira/views/*'] } ],
);
my $authorless = run_cli( 'record.create', '--title', 'no author given', '--column', 'gated-only-conditional' );
ok( !$authorless->{died}, 'creating into a column whose ONLY required_action is conditional needs no --author - nothing will run required_item_add for it' );

done_testing();

__END__

=head1 NAME

t/936-a-gate-blind-to-what-it-touched.t - the verify column's browser-test
gate the docs once claimed, now built: conditional on the card's own commits

=head1 DESCRIPTION

TKT-799 found docs/commands.md claiming a conditional required action on
verify (fires when a card's changes touch a browser-relevant path, asking for
tools/browser-tests before the card can leave) that this board's project
configuration never actually carried - and corrected the doc to say so
honestly. TKT-936 tracks building the gate the doc originally described.

Q-154 settled the design: a required-action template entry (on either a
column's required_actions or entry_required_actions list) may now be a hash
C<{ text =E<gt> TEXT, touches =E<gt> [PATTERN, ...] }> instead of a plain
string. At move-time, C<_populate_column_required_actions> and
C<_populate_entry_required_actions> resolve a conditional entry by reading
the card's own git history - C<_record_touched_paths> reads every commit's
hash and subject line, keeps only those whose subject names this card's ref
as an EXACT ref-shaped token (not a substring - a bare C<git log --grep>
would let a short ref match a longer one sharing its prefix, and would match
a passing mention in a commit's body too), then reads only the matching
commits' changed paths - and only places the item if one of those paths
matches one of the patterns. No matching commit, or no match among the paths
it touched, and the item is never placed - the card is unaffected, not
blocked on an item it will never be told about.

A pattern with no C<'/'> matches by basename anywhere in the tree
(C<DashboardWeb.pm> matches C<lib/Tira/DashboardWeb.pm>); a pattern with
C<'/'> matches by prefix, so a trailing C<'*'> reaches everything under a
directory (C<lib/Tira/views/*>).

A plain string item is unaffected by any of this - it is still placed
unconditionally, exactly as it always was. The mechanism is additive, not a
replacement for the existing template shape.

=cut
