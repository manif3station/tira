#!/usr/bin/env perl
# A card damaged by one byte is read, not set aside.
#
# TKT-180 stopped a single malformed byte silencing a whole board, by skipping
# the card whose history could not be decoded and naming it. He read that and
# said the obvious thing back: do not skip it, read it.
#
# He is right, and the skip is the weaker answer by this project's own
# standard. A skipped card is a card nobody is checking, and the entire point of
# that release was that a card nobody checks is indistinguishable from a card
# with nothing wrong. The fix reproduced the disease at a smaller scale.
#
# His diagnosis was also nearly exact. Perl opens the file perfectly well; it is
# the strict UTF-8 JSON decode that treats a malformed byte as fatal. Decoding
# with substitution instead of refusal returns the whole entry - proved on his
# own damaged line before any of this was written:
#
#     strict decode  : dies
#     lenient decode : field=title, ref=M5T-034, and the full text, with the
#                      single 0xD7 shown as a replacement character
#
# He offered to bring in Python or C to clean the file. That is not needed and
# would be the wrong shape: a second language added to work around a flag.
#
# Two things must survive the change. The damage must still be reported, or a
# corrupt record becomes invisible - which is the original fault again. And
# nothing may rewrite the file: history is the permanent record, and a program
# that edits it unattended is a worse problem than the one it solves.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-14T22:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Damaged', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'DMS', epic_prefix => 'DME', ticket_prefix => 'DMT',
);
$tira->policy_add( project => $root, rule => 'column-skipped',
    enter => 'verify', require => 'implement', action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Damaged, and skipping verify' )->{ref};

# Straight to verify without passing through implement, which is what
# column-skipped exists to report. It reads history to find that out, so it is
# the rule that meets the damage.
$tira->record_move(author => 'claude',  project => $root, ref => $card, column => 'verify' );

my $journal = File::Spec->catfile( $root, '.tira', 'history', "$card.jsonl" );
open my $append, '>>:raw', $journal or die $!;
print {$append} qq({"after":"Workflow finder \xd72 + 3 independent refuters","at":)
  . qq("2026-08-14T22:00:00Z","author":null,"before":null,"field":"title",)
  . qq("op":"update","ref":"$card"}\n);
close $append;

open my $before, '<:raw', $journal or die $!;
my $original = do { local $/; <$before> };
close $before;

# --- the entry comes back rather than the read failing -----------------------------
#
# His measurement, as a test. Everything in the line survives except the byte
# that was never valid.

my $history = eval { $tira->history_list( project => $root, ref => $card ) };
ok( !$@, 'a history with a malformed byte in it can be read' ) or diag($@);

my ($damaged) = grep { ( $_->{after} // '' ) =~ /Workflow finder/ } @{ $history // [] };
ok( $damaged, 'and the damaged entry is one of the entries, not a gap' );
is( $damaged->{field}, 'title', 'with its field intact' );
is( $damaged->{ref}, $card, 'and its reference' );
like( $damaged->{after}, qr/3 independent refuters/,
    'and the text after the bad byte, which is what makes this worth reading rather than skipping' );

# --- and the card is checked like any other -------------------------------------------
#
# The whole point. Under TKT-180 this card was set aside, so the violation it
# was actually carrying went unreported - a card nobody checks looking exactly
# like a card with nothing wrong, one level down from the fault that release
# fixed.

my $pass = $tira->police_pass( project => $root, store => $store,
    world => { branches => [], worktrees => [], processes => [], containers => [] } );

my @skipped = grep { $_->{rule} eq 'column-skipped' } @{ $pass->{violations} };
is( scalar @skipped, 1,
    'the damaged card is judged by the rule that had to read its history' );
is( $skipped[0]{ref}, $card, 'and it is the damaged card that is named' );

# --- while the damage is still said, once -----------------------------------------------
#
# Reading past it silently would make a corrupt record invisible, which is the
# original fault wearing a different coat.

my @noted = grep { $_->{rule} eq 'card-damaged' } @{ $pass->{violations} };
is( scalar @noted, 1, 'and the damage is still reported' );
is( $noted[0]{ref}, $card, 'against the card whose file it is in' );
like( $noted[0]{detail}, qr/UTF-8|malformed|substitut/i, 'saying what was wrong' );

is_deeply( $pass->{unreadable}, [],
    'and nothing is listed as unreadable any more, because nothing was left unread' );

# --- said once, however many rules had to open the file ---------------------------------
#
# Two rules read a card's journal by different routes - column-skipped through
# the column list, conversation-not-folded through _last_card_change - so a
# board declaring both opens the same damaged file twice in one pass. The
# damage is one fact about one card, and hearing it twice because two rules
# happened to look would teach a reader that the count means nothing.

{
    my $both = File::Spec->catdir( $tmp, 'both' );
    my $ledger = File::Spec->catdir( $tmp, 'police-both' );
    $tira->project_new(
        name => 'Twice', dir => $both, members => [ 'michael', 'claude' ],
        columns => ['backlog, implement, verify, done'],
        sow_prefix => 'TWS', epic_prefix => 'TWE', ticket_prefix => 'TWT',
    );
    $tira->policy_add( project => $both, rule => 'column-skipped',
        enter => 'verify', require => 'implement', action => 'bridge-reminder' );
    $tira->policy_add( project => $both, rule => 'conversation-not-folded',
        action => 'bridge-reminder' );

    my $twice = $tira->create_record( project => $both, type => 'ticket',
        title => 'Read by two rules in one pass' )->{ref};
    $tira->record_move(author => 'claude',  project => $both, ref => $twice, column => 'verify' );

    # conversation-not-folded only opens the journal of a card with something
    # said on it, so without this the second reader never runs. Said an hour
    # after the card was last written, because the rule compares the two - with
    # one fixed clock the comment lands in the same instant as the move that
    # created it and the rule correctly declines to fire.
    my $later = Tira->new( clock => sub {'2026-08-14T23:00:00Z'} );
    $later->comment_add( project => $both, ref => $twice, author => 'michael',
        text => 'Said here and not folded in, so the second rule has to look' );

    my $file = File::Spec->catfile( $both, '.tira', 'history', "$twice.jsonl" );
    open my $damage, '>>:raw', $file or die $!;
    print {$damage} qq({"after":"Adversarial-verified LOW\xd72","at":)
      . qq("2026-08-14T22:00:00Z","author":null,"before":null,"field":"title",)
      . qq("op":"update","ref":"$twice"}\n);
    close $damage;

    my $seen = $tira->police_pass( project => $both, store => $ledger,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );

    is( scalar( grep { $_->{rule} eq 'card-damaged' } @{ $seen->{violations} } ), 1,
        'a card two rules had to read is reported damaged once, not once per rule' );
    is( scalar @{ $seen->{damaged} // [] }, 1, 'and appears once in what the pass hands back' );
    is( $seen->{damaged}[0]{ref}, $twice, 'as the card it is' );

    # And both rules still judged it - reading past the byte rather than
    # skipping means _police_history still ran for both, which is what the
    # dedup above actually proves. column-skipped itself is now settled by
    # the very comment this scenario added to give conversation-not-folded
    # something to fire on - TKT-284's own comment-settles behaviour, not a
    # gap in the dedup: it read the damaged journal (the damage was still
    # found and reported once, above) and then judged the card settled.
    ok( !scalar( grep { $_->{rule} eq 'column-skipped' && $_->{ref} eq $twice }
            @{ $seen->{violations} } ),
        'while the first rule read the same damaged journal and judged the card settled by its comment' );
    ok( scalar( grep { $_->{rule} eq 'conversation-not-folded' && $_->{ref} eq $twice }
            @{ $seen->{violations} } ),
        'and the second still judged it, unaffected' );
}

# --- and the file on disk is untouched ------------------------------------------------------
#
# Police does not repair anybody's records behind their back. Cleaning a file is
# a separate command somebody runs on purpose.

open my $after, '<:raw', $journal or die $!;
my $now = do { local $/; <$after> };
close $after;
is( $now, $original, 'the history file is byte for byte what it was' );
like( $now, qr/\xd7/, 'bad byte and all - nothing was quietly rewritten' );

# --- a clean board is unchanged ---------------------------------------------------------------

{
    my $clean = File::Spec->catdir( $tmp, 'clean' );
    my $quiet = File::Spec->catdir( $tmp, 'police-clean' );
    $tira->project_new(
        name => 'Clean', dir => $clean, members => ['michael', 'claude' ],
        columns => ['backlog, implement, verify, done'],
        sow_prefix => 'CLS', epic_prefix => 'CLE', ticket_prefix => 'CLT',
    );
    $tira->policy_add( project => $clean, rule => 'column-skipped',
        enter => 'verify', require => 'implement', action => 'bridge-reminder' );
    my $ok = $tira->create_record( project => $clean, type => 'ticket',
        title => 'Nothing wrong with this one' )->{ref};
    $tira->record_move(author => 'claude',  project => $clean, ref => $ok, column => 'verify' );

    my $result = $tira->police_pass( project => $clean, store => $quiet,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is( scalar( grep { $_->{rule} eq 'card-damaged' } @{ $result->{violations} } ), 0,
        'a board with no damaged file says nothing about damage' );
    is( scalar( grep { $_->{rule} eq 'column-skipped' } @{ $result->{violations} } ), 1,
        'and its own violations are reported exactly as before' );
}

done_testing;

__END__

=head1 NAME

173-a-damaged-card-is-still-read.t - one bad byte does not cost a card its checks

=head1 DESCRIPTION

C<TKT-180> stopped a malformed byte silencing a whole board by skipping the card
it could not decode. That is the same fault at a smaller scale: a skipped card
is a card nobody is checking, which is what the release was about.

History is now decoded with substitution rather than refusal, so the entry comes
back whole apart from the byte that was never valid, and every rule judges the
card normally. The damage is still reported once, so a corrupt record does not
become invisible, and the file on disk is not touched - repairing a record is a
separate command somebody runs deliberately.

=cut
