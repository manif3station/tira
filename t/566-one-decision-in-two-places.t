#!/usr/bin/env perl
# TKT-610. The most expensive recurring fault on this board is one decision
# implemented in two places and fixed in one of them - five instances on
# 2026-08-27 alone, two of them mine after filing cards about it. Nothing
# detected any of them. Meanwhile this suite already polices narrower
# patterns with meta-tests: t/147 refuses an assertion that passes on empty
# input, t/121 refuses a control the page cannot honour, t/344 refuses POD
# that does not match what the CLI calls, t/220 refuses a second way of
# saying which board.
#
# THE REGISTRY IS THE DELIVERABLE, NOT ANY ONE RULE. Its value is that the
# next pair costs a line here instead of a new file, so the answer to "we
# just fixed that in one place again" is cheap enough to actually take.
#
# WHAT THIS CANNOT DO, said plainly because a guard that oversells itself is
# worse than none. It cannot find an unknown pair - only stop a known one
# drifting. It reads source text, so it sees the shape of a call and not its
# meaning, and a bypass spelled differently enough will pass. It is a
# ratchet, not a search.
#
# A WHITELISTED BYPASS MUST STATE WHY. Without that the list quietly becomes
# everything, which is how the original decisions came to have two homes.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();

sub tool_source {
    my ($name) = @_;
    my $path = "tools/$name";
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

# --- the registry ----------------------------------------------------------
#
# Each entry: the decision, why it has one home, where to look, what a bypass
# looks like, and the sites allowed to bypass it with the reason each is
# allowed. `allowed` is matched against the offending line.

my @DECISIONS = (
    {
        name => 'a list read whose board was guessed answers through the namer',
        why  => 'TKT-962, then TKT-964. Three reads resolve their board with '
          . 'discover_project when the caller names none - job_list, '
          . 'tasklist_list and warning_list - and each treats an absent file '
          . 'as an empty result. Together those two halves answer a caller '
          . 'standing somewhere unexpected confidently, for a board they did '
          . 'not mean: he was given an empty jobs list for a board with '
          . 'three and declined four safety rules against it. The sentence '
          . 'that names the board has one home, Tira::CLI::Board::'
          . '_empty_answer_names_board, because the first copy was written '
          . 'inline in job.list and the next two verbs would have copied it. '
          . 'A dispatch branch that RETURNS one of those lists straight to '
          . 'the caller has bypassed it. LIMIT, stated rather than left to '
          . 'be discovered: this catches the direct-return shape and not a '
          . 'list returned through a variable, which is what job.list '
          . 'itself looked like before TKT-964 (my $jobs = ...; return '
          . '$jobs). Verified both directions by hand - it catches the two '
          . 'pre-fix dispatch lines and leaves every legitimate job_list '
          . 'call alone - so it is a ratchet against the obvious relapse, '
          . 'not a proof.',
        source  => sub { Suite::cli_source() },
        bypass  => qr/return \s+ \$tira->(?:job_list|tasklist_list|warning_list) \s* \(/x,
        allowed => [],
    },
    {
        name => 'column_list is always asked for a specific type',
        why  => 'TKT-597, and TKT-532 before it on the browser path. A '
          . 'typeless call falls back to a default board, so a guard '
          . 'walked a card through another type\'s gated columns and '
          . 'refused with a reason that named columns the card never had. '
          . 'The type is recovered from the record the caller already '
          . 'holds; the recovery is the decision, and it has one home.',
        source  => sub { Suite::engine_source() },
        bypass  => qr/column_list\s*\(\s*(?![^()]*\btype\s*=>)[^()]*\)/,
        allowed => [],
    },
    {
        name => 'column_list is always asked for a specific type - command surface',
        why  => 'TKT-947, correcting TKT-610. The entry above is sourced from '
          . 'engine_source, which deliberately excludes lib/Tira/CLI - and '
          . 'EVERY column_list call site in this codebase is in that layer. '
          . 'So the decision the registry was built for was guarded where it '
          . 'is not called and unguarded where it is. Eight sites today, one '
          . 'of which is the recovery itself; the rest all know their type, '
          . 'and the ones listed below say so somewhere other than inside the '
          . "call's own parentheses, which is what the pattern reads.",
        source  => sub { Suite::cli_source() },
        bypass  => qr/column_list\s*\(\s*(?![^()]*\btype\s*=>)[^()]*\)/,
        allowed => [
            {   where   => qr/return eval \{ \$tira->column_list\( %\{\$args\} \) \}/,
                because => 'this is _columns_for itself - the recovery TKT-597 '
                  . 'built, which sets $args->{type} from the record on the '
                  . 'line above and then makes the call. It is the decision, '
                  . 'not a bypass of it, and naming it here is how a reader '
                  . 'tells the two apart.',
            },
            {   where   => qr/column_list\(%args\) if \$command eq 'column\.list'/,
                because => 'the column.list dispatch. That command requires '
                  . '--type (TKT-409), so the caller has already said which '
                  . 'board they mean and %args carries it.',
            },
            {   where   => qr/my \$columns = eval \{ \$tira->column_list\(%args\) \};/,
                because => 'the two calls in record_create, which is reached '
                  . 'only from the record.create dispatch - and the create '
                  . 'verbs are ticket.create, epic.create and sow.create, each '
                  . 'setting the type from the verb itself. The type is in '
                  . '%args; it simply arrives through the hash rather than at '
                  . 'the call, which is the one place a future reader could be '
                  . 'misled, so it is written down here.',
            },
            {   where   => qr/eval \{ \$tira->column_list\(%column_args\) \}/,
                because => 'the browser move provider. %column_args is built '
                  . 'on the line above as ( %move_args, type => '
                  . '$record->{type} ) - recovered from the record record_move '
                  . 'already loaded, under TKT-532\'s own principle that a '
                  . 'caller is never required to say what the engine can '
                  . 'already tell for itself.',
            },
        ],
    },
    {
        name => "a status compared to 'done' is lowercased first",
        why  => 'TKT-601. The dashboard read required-action status '
          . 'case-sensitively while the engine did not, so an item stored '
          . "as 'Done' was finished to one and unfinished to the other. "
          . 'Q-099 then gave statuses a tight vocabulary, which narrows '
          . 'the input but does not remove the need for the comparison to '
          . 'agree with itself in every place it is made.',
        source => sub { Suite::engine_source() . "\n" . Suite::cli_source('CLI.pm') },
        bypass => qr/^(?!.*\blc\b).*\bstatus\b[^\n]*\beq\s*['"]done['"]/m,
        allowed => [],
    },
    {
        name => 'the coverage gate derives its module list from lib/',
        why  => 'TKT-594. It named three modules by hand, so '
          . 'lib/Tira/OnboardWeb.pm had no coverage requirement at all for '
          . 'four releases and nothing said so. A list that must be '
          . 'maintained alongside the thing it describes is the same fault '
          . 'as a decision with two homes.',
        source => sub { tool_source('gate-run') },
        bypass => qr/^\s*modules=\(\s*["']?lib\//m,
        allowed => [],
    },
    {
        name => 'a checklist item is created or moved to done through _proof_entries_for',
        why  => 'TKT-958. checklist_update refuses a done status with no '
          . '--command/--proof pair, routed through _proof_entries_for '
          . '(TKT-628) - checklist_add wrote a checklist entry\'s status '
          . 'directly and never called it, so an item could be CREATED '
          . 'already done with no evidence at all, bypassing the exact rule '
          . 'its own sibling verb enforces on every later write to the same '
          . 'field. Any sub that writes a checklist entry\'s status without '
          . 'going through the shared helper reopens that gap.',
        source  => sub { Suite::engine_source() },
        bypass  => qr/(?:CHK-%03d.*status\s*=>\s*\$args\{status\}|\{status\}\s*=\s*\$args\{status\})/,
        allowed => [
            {   where   => qr/id => sprintf\( 'CHK-%03d', \$number \), item => \$args\{item\}, status => \$args\{status\}/,
                because => 'checklist_add itself - it now calls '
                  . '_proof_entries_for before this line is ever reached, '
                  . 'refusing a done status with no pair first.',
            },
            {   where   => qr/\$entry->\{status\} = \$args\{status\} if defined \$args\{status\};/,
                because => 'both checklist_update and required_item_update '
                  . 'share this exact line shape - both call '
                  . '_proof_entries_for earlier in the same sub, before this '
                  . 'assignment is reached.',
            },
        ],
    },
);

# --- the engine that reads the registry ------------------------------------
#
# Kept as a named sub so the registry can be exercised against a synthetic
# decision below. A guard nobody has watched fail is a guard nobody knows
# works.

sub bypasses_in {
    my ($decision) = @_;
    my $text = $decision->{source}->();
    my @hits;
    for my $line ( split /\n/, $text ) {
        next if $line !~ $decision->{bypass};
        next if $line =~ /^\s*#/;          # a comment describing the fault is not the fault
        my $excused = 0;
        for my $allow ( @{ $decision->{allowed} || [] } ) {
            next if $line !~ $allow->{where};
            $excused = 1;
            last;
        }
        push @hits, $line if !$excused;
    }
    return \@hits;
}

# --- every registered decision still has one home --------------------------

for my $decision (@DECISIONS) {
    my $hits = bypasses_in($decision);
    is_deeply( $hits, [], "$decision->{name} - no site bypasses it" )
      or diag( "why this decision has one home:\n  $decision->{why}\n"
          . "bypassing lines:\n  " . join( "\n  ", @{$hits} ) );
}

# --- a whitelisted bypass must say why it is allowed -----------------------
#
# The list is what stops this test being deleted a line at a time, so the
# list itself is checked. An entry with no reason is not an exemption, it is
# an unexplained hole.

for my $decision (@DECISIONS) {
    for my $allow ( @{ $decision->{allowed} || [] } ) {
        ok( defined $allow->{because} && $allow->{because} =~ /\S/,
            "$decision->{name} - every whitelisted site states why it is allowed" )
          or diag('an exemption with no reason is how a list becomes everything');
    }
}

# --- the registry engine itself, exercised against a synthetic decision ----
#
# CHK-005 on the card: a new bypass must fail and a reasoned one must pass.
# Proved on text this file owns, so the assertion does not depend on the real
# source happening to contain a violation.

{
    my $clean = "my \$x = helper( type => 'ticket' );\n";
    my $dirty = "my \$x = helper();\n";
    my %shape = (
        name   => 'synthetic',
        why    => 'exercises the registry engine',
        bypass => qr/helper\s*\(\s*(?![^()]*\btype\s*=>)[^()]*\)/,
    );

    is_deeply( bypasses_in( { %shape, source => sub {$clean}, allowed => [] } ), [],
        'a compliant site is not reported' );

    my $caught = bypasses_in( { %shape, source => sub {$dirty}, allowed => [] } );
    is( scalar @{$caught}, 1, 'a new bypass IS caught - the whole point of the ratchet' );

    is_deeply(
        bypasses_in( {
            %shape, source => sub {$dirty},
            allowed => [ { where => qr/helper/, because => 'a stated reason' } ],
        } ),
        [],
        'and a whitelisted bypass passes, so a genuine exception can be recorded rather than the test deleted'
    );

    is_deeply(
        bypasses_in( {
            %shape, source => sub {"# helper();\n"}, allowed => [],
        } ),
        [],
        'a comment describing the fault is not the fault - this file is full of such comments, and so is the code it reads'
    );
}

# --- the header says what it cannot do -------------------------------------
#
# The card asks for this in as many words, and it is the difference between a
# ratchet and a claim of completeness.

{
    open my $fh, '<:raw', $0 or die $!;
    my $self = do { local $/; <$fh> };
    close $fh;
    # non-empty is the whole claim: the checks below would pass on an
    # unreadable file's emptiness alone otherwise.
    like( $self, qr/\S/, 'this file is there to be read' );
    like( $self, qr/cannot find an unknown pair/,
        'the header says plainly that it stops a known decision drifting rather than finding new ones' );
    like( $self, qr/ratchet, not a search/,
        'and names what it is, so nobody reads a passing run as proof there are no other pairs' );
}

done_testing();

__END__

=head1 NAME

566-one-decision-in-two-places.t - a registry of decisions that must keep one home

=head1 DESCRIPTION

TKT-610. One decision implemented in two places and fixed in one of them is
the most expensive recurring fault on this board, and nothing detected it,
though the suite already carries meta-tests for narrower patterns. This holds
a registry: each entry names a decision, why it has one home, where to look,
what a bypass looks like, and which sites may bypass it and for what stated
reason. Adding the next one costs a line rather than a file.

It is a ratchet, not a search. It cannot find an unknown pair - only stop a
known one drifting - and it reads source text, so it sees the shape of a call
rather than its meaning.

=cut
