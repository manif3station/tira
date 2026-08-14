#!/usr/bin/env perl
# One card nobody can read does not silence the board.
#
# He reported that answering a question raised a bridge note on one of his
# boards and not on the other, with the same rule declared on both. It was not
# the answer rule. On mt5 police was reporting zero violations across 27
# declared policies and 359 cards, saying watching=1, and exiting 0 - so the
# board looked perfectly clean while nothing at all was being enforced.
#
# Two history files held one byte that is not valid UTF-8: a raw 0xD7 where a
# multiplication sign was meant, written as latin-1 in "Workflow finder x2 + 3
# independent refuters". history_list decodes strict UTF-8 and dies on it, and
# two rules read history with no guard - conversation-not-folded, through
# _last_card_change, and column-skipped. The die aborts the whole pass at the
# first bad card, so every other rule stops there too.
#
# That particular byte is no longer an example of an unreadable card: he asked
# for it to be read rather than skipped, and 173 covers that. What this file
# still guards is the shape underneath it - a journal line that nothing can
# read, which is what a half-written line after a crash looks like - because a
# board must not go silent for one of those either.
#
# Removing both rules from a copy produced three violations instantly, two of
# them real and hidden on his production board for as long as the byte had been
# there.
#
# The byte is the trigger. The defect is that police caught the failure, put it
# in a field nothing reads, and then returned an empty violation list that is
# indistinguishable from a clean pass. A third history reader in the same file,
# _policy_last_detail_change, already guards its read - so the safe shape was
# written once and two copies of the same decision drifted from it.
#
# Skipping the card quietly would be the same disease one level down. A card
# police cannot read is something it has to say out loud.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-14T19:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Unreadable', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'UNS', epic_prefix => 'UNE', ticket_prefix => 'UNT',
);

# One rule that reads history and one that does not. The second is the whole
# point: it has no reason to care about a byte in another card's journal.
$tira->policy_add( project => $root, rule => 'column-skipped',
    enter => 'verify', require => 'implement', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'answer-waiting',
    action => 'bridge-reminder' );

# The other history reader, and the one his board declared. It reaches the
# journal by a different route - _last_card_change rather than the column list
# - so a guard on one of them proves nothing about the other. That is exactly
# how these two drifted apart from the third reader in the first place.
$tira->policy_add( project => $root, rule => 'conversation-not-folded',
    action => 'bridge-reminder' );

sub card {
    my ($title) = @_;
    return $tira->create_record( project => $root, type => 'ticket', title => $title )->{ref};
}

# --- a card that is fine, and has something to report ----------------------------
#
# An answer nobody has read. This is the violation he was looking for, and the
# one that has to survive whatever is wrong with a different card.

my $good = card('An answered question nobody has read');
my $question = $tira->question_add( project => $root, ref => $good, author => 'claude',
    text => 'Does this still get reported?', reason => 'It must not depend on another card',
    options => [ 'yes', 'no' ] );
$tira->question_answer( project => $root, ref => $good, id => $question->{id},
    author => 'michael', text => 'It must' );

# --- and a card whose history cannot be decoded ------------------------------------
#
# His byte, exactly: 0xD7 alone inside a JSON string, which is what a
# multiplication sign written as latin-1 looks like on disk.

my $broken = card('A card whose journal has a bad byte in it');

# In the column the history-reading rule watches, and damaged afterwards - the
# move is what makes column-skipped open its journal at all, and a card it
# never opens proves nothing.
$tira->record_move( project => $root, ref => $broken, column => 'verify' );

# A comment on it, so conversation-not-folded has something to weigh and has to
# open the journal to weigh it. Without this the second reader never runs and
# the guard on it is never proved.
$tira->comment_add( project => $root, ref => $broken, author => 'michael',
    text => 'Something said here that nobody has folded into the card yet' );

my $journal = File::Spec->catfile( $root, '.tira', 'history', "$broken.jsonl" );
ok( -f $journal, 'the broken card has a history file to damage' );

# A line that stops halfway, which is what a journal looks like when the
# process writing it died. The byte that started all this is no longer an
# example of an unreadable card - TKT-191 reads past that, and 173 covers it -
# but a line that is not JSON at all still cannot be read by anything, and the
# board must survive one of those exactly as it survives the other.
open my $append, '>>:raw', $journal or die $!;
print {$append} qq({"after":"stopped mid-write","at":"2026-08-14T19:00:0\n);
close $append;

ok( !eval { $tira->history_list( project => $root, ref => $broken ); 1 },
    'and reading that history really does fail, so the rest of this is about a real fault' );

# --- the pass survives it ------------------------------------------------------------
#
# Every other card is still checked. This is what was lost: 27 rules stopped at
# the first bad byte and a board of 359 cards reported nothing.

my $pass = $tira->police_pass( project => $root, store => $store,
    world => { branches => [], worktrees => [], processes => [], containers => [] } );

my @answers = grep { $_->{rule} eq 'answer-waiting' } @{ $pass->{violations} };
is( scalar @answers, 1,
    'the answered question is still reported, on a board where another card cannot be read' );
like( $answers[0]{detail}, qr/\Q$question->{id}\E/, 'naming the question' );

# --- and says which card it could not read --------------------------------------------
#
# Skipping it silently would be the same fault as the one being fixed: a card
# nobody can check would look exactly like a card with nothing wrong.

# Neither history-reading rule reports it. An unreadable journal is not an
# unwritten card, and a rule that treated it as one would be inventing a
# violation out of a fault of its own. Being reported as unreadable is a
# different thing and is exactly what should happen.
is_deeply(
    [ grep { $_->{ref} eq $broken && $_->{rule} ne 'card-unreadable' }
        @{ $pass->{violations} } ],
    [],
    'and the card nobody could read is not accused of anything on the strength of that' );

ok( defined $pass->{unreadable}, 'the pass says something about what it could not read' );
is_deeply( [ map { $_->{ref} } @{ $pass->{unreadable} // [] } ], [$broken],
    'naming the card whose history could not be decoded' );
# What was wrong, not merely that something was. This was widened to qr/\S/
# when the damage changed from a bad byte to a half-written line, which is
# exactly how an assertion stops being able to fail. TKT-196.
like( $pass->{unreadable}[0]{reason} // '', qr/JSON|garbage|parse|unexpected|malformed|UTF-8/i,
    'and saying what was wrong with it, in terms of the thing that could not be read' );

# What the owner reads is about his card, not about where the decoder was
# standing when it gave up.
unlike( $pass->{unreadable}[0]{reason} // '', qr/\bat \S+ line \d+/,
    'without the file and line number of the parser, which is not his to act on' );

# --- out loud, where somebody sees it -----------------------------------------------
#
# The error field this already had is read by nothing. The bridge is written
# from the violation list and the terminal from escalations, so a failure that
# lands in neither is a failure nobody hears about.

my @unreadable = grep { $_->{rule} eq 'card-unreadable' } @{ $pass->{violations} };
is( scalar @unreadable, 1, 'and says so on the bridge, as a violation like any other' );
is( $unreadable[0]{ref}, $broken, 'against the card it could not read' );
like( $unreadable[0]{detail}, qr/could not be read/, 'saying why' );
ok( defined $unreadable[0]{id}, 'with a number of its own, so it can be referred to' );

# --- said once, not every thirty seconds for ever -----------------------------------------
#
# The first version printed this to the terminal on every pass. The byte that
# prompted it is in somebody else's file and six days old, so that is a line
# every thirty seconds for the rest of the board's life, and he read it back
# within the hour: "I thought you have a workaround". The workaround worked -
# the telling of it was the repetition a warning system dies of, added by the
# fix for a silence.

{
    my $again = $tira->police_pass( project => $root, store => $store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    my ($repeat) = grep { $_->{rule} eq 'card-unreadable' } @{ $again->{violations} };
    ok( $repeat, 'it is still true on the next pass, because the byte has not gone anywhere' );
    ok( $repeat->{quiet}, 'and is not said again, because it is on the quiet ladder like everything else' );
    is( $repeat->{id}, $unreadable[0]{id}, 'still the same one rather than a new one each pass' );
    is_deeply( [ grep { /history could not be read/ } @{ $again->{terminal} // [] } ], [],
        'and nothing reaches the terminal for a fault that has already been reported' );
}

# --- while a board with nothing wrong with it is unchanged -------------------------------
#
# The guard must not become a thing that speaks up on every clean pass.

{
    my $clean = File::Spec->catdir( $tmp, 'clean' );
    my $elsewhere = File::Spec->catdir( $tmp, 'police-clean' );
    $tira->project_new(
        name => 'Readable', dir => $clean, members => ['michael'],
        columns => ['backlog, implement, verify, done'],
        sow_prefix => 'RDS', epic_prefix => 'RDE', ticket_prefix => 'RDT',
    );
    $tira->policy_add( project => $clean, rule => 'column-skipped',
        enter => 'verify', require => 'implement', action => 'bridge-reminder' );
    $tira->create_record( project => $clean, type => 'ticket', title => 'Nothing wrong here' );

    my $quiet = $tira->police_pass( project => $clean, store => $elsewhere,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is_deeply( $quiet->{unreadable} // [], [],
        'a board with no unreadable card reports none' );
    is_deeply( [ grep { /could not be read/i } @{ $quiet->{terminal} // [] } ], [],
        'and says nothing to the terminal about reading' );
}

# --- a pass that failed outright is never presentable as a clean one --------------------
#
# The half that would have caught this on the first day. Whatever goes wrong,
# an empty violation list and a failure must not look the same from outside.

{
    my $blind = Tira->new( clock => sub {'2026-08-14T19:00:00Z'} );
    no warnings 'redefine';
    local *Tira::policy_evaluate = sub { die "the board is unreadable\n" };
    my $failed = $blind->police_pass( project => $root, store => $store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    ok( defined $failed->{error}, 'a pass that could not run says so' );
    like( join( "\n", @{ $failed->{terminal} // [] } ), qr/unreadable|could not/i,
        'and says it where the owner is looking, not only in a field nothing reads' );
}

# --- and a pass that failed settles nothing -------------------------------------------------
#
# The worst of it, and it was live in the release that fixed the silence. An
# empty violation list means "everything open is now resolved", and a pass that
# died hands back an empty list - so a crash announced every open violation as
# fixed. On his board the last thing the dying pass ever said was
#
#     SETTLED | VIO-0018 | answer-ok-not-folded no longer applies here
#     | fix: nothing - this one is over
#
# nine seconds after the rule that killed it was declared. Silence is
# ambiguous. "This one is over" is a false statement about work nobody did.

{
    my $order = File::Spec->catdir( $tmp, 'settle' );
    my $ledger = File::Spec->catdir( $tmp, 'police-settle' );
    $tira->project_new(
        name => 'Settling', dir => $order, members => ['michael'],
        columns => ['backlog, done'],
        sow_prefix => 'SES', epic_prefix => 'SEE', ticket_prefix => 'SET',
    );
    $tira->policy_add( project => $order, rule => 'gate-missing', column => 'done',
        action => 'bridge-reminder' );
    my $shipped = $tira->create_record( project => $order, type => 'ticket',
        title => 'Reached the end with nothing recorded' );
    $tira->record_move( project => $order, ref => $shipped->{ref}, column => 'done' );

    my $world = { branches => [], worktrees => [], processes => [], containers => [] };
    my $raised = $tira->police_pass( project => $order, store => $ledger, world => $world );
    is( scalar @{ $raised->{violations} }, 1, 'a real violation is raised while the pass works' );
    my $id = $raised->{violations}[0]{id};

    my $crashed;
    {
        no warnings 'redefine';
        local *Tira::policy_evaluate = sub { die "the board is unreadable\n" };
        $crashed = $tira->police_pass( project => $order, store => $ledger, world => $world );
    }
    is_deeply( $crashed->{settled}, [],
        'and a pass that failed settles nothing, because it established nothing' );

    my $after = $tira->police_pass( project => $order, store => $ledger, world => $world );
    is( scalar @{ $after->{violations} }, 1, 'the violation is still open afterwards' );
    is( $after->{violations}[0]{id}, $id,
        'and is the same one, rather than closed by the crash and raised again as new' );
    ok( !$after->{violations}[0]{returned},
        'so nobody is told a fixed problem has come back when it never went away' );
}

done_testing;

__END__

=head1 NAME

170-a-board-that-could-not-be-read.t - one unreadable card does not silence the board

=head1 DESCRIPTION

A single card whose history journal contained one byte of invalid UTF-8 stopped
every rule on a board of 359 cards: the decode died inside the rule loop,
C<police_pass> caught it into a field nothing reads, and returned an empty
violation list with C<watching> set - which is indistinguishable from a board
with nothing wrong. Two real violations were hidden that way.

The pass now survives a card it cannot read, still reports every other card,
names the card and why, and says so in the owner's terminal. A pass that failed
outright can no longer present itself as a clean one, and a board with nothing
unreadable says nothing new.

=cut
