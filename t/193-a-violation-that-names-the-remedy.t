#!/usr/bin/env perl
# A reported corruption says where it is and what to run about it.
#
# mt5-ai, 2026-08-15: two cards raising card-damaged and nothing they could do
# about either. The bad byte is in an old history entry, history is append-only
# by design, and the record-level recovery the changelog documents cannot reach
# it - they tried, by commenting on each card, which only appended.
#
# Their words for why it matters past tidiness: "an unfixable violation sits open
# for ever and is indistinguishable from one being ignored... a line that cannot
# be acted on teaches whoever reads the bridge that some lines are not worth
# acting on." That is this guide's own argument turned on one of its own rules.
#
# Two things were missing and one of them already shipped. tira.doctor repairs it
# and has since 1.94; their installed copy is older, which is TKT-129 and not
# this card. What is missing here is that the violation never mentions it. Every
# violation carrying a card gets "fix: d2 tira.ticket.show --ref X", which is
# right almost everywhere and wrong for the one rule whose remedy is a specific
# command - so the single rule that has a command to name is the single rule that
# does not name it.
#
# And where. They asked for the entry and the offset "so a human can judge
# whether anything was actually lost", which is the right thing to be able to ask
# of a record: the card said a byte was substituted while reading and nothing
# about which byte, so a mangled multiplication sign and a mangled digit in a
# figure somebody is relying on read exactly alike.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'board' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Damaged', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'DGS', epic_prefix => 'DGE', ticket_prefix => 'DGT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card with a damaged journal' )->{ref};

# Their byte: a multiplication sign written as latin-1, in an entry that is
# already history by the time anybody notices.
my $journal = File::Spec->catfile( $root, '.tira', 'history', "$card.jsonl" );
open my $damage, '>>:raw', $journal or die $!;
print {$damage} qq({"after":"Workflow finder \xd72 + 3 refuters","at":"2026-08-15T09:00:00Z",)
  . qq("author":null,"before":null,"field":"title","op":"update","ref":"$card"}\n);
close $damage;

# Something has to read the history, because that is what notices the damage.
# Nothing scans a board for corruption on its own: the byte is found by a rule
# opening the card's journal for its own reasons.
#
# conversation-not-folded is that rule, and it only opens a card that HAS
# comments - so the card needs one. Both facts were found by writing this test
# without them and watching the damage go unreported twice: a board with no
# history-reading policy never learns it is damaged, and neither does a card
# nothing has reason to open. That is why mt5-ai saw it on the two cards they
# had commented on.
$tira->policy_add( project => $root, rule => 'conversation-not-folded',
    action => 'bridge-reminder' );
$tira->comment_add( project => $root, ref => $card, author => 'claude',
    text => 'Something to make a rule open this card at all' );

my $pass = $tira->police_pass( project => $root, store => $store,
    world => { branches => [], worktrees => [], processes => [], containers => [] } );

my ($damaged) = grep { $_->{rule} eq 'card-damaged' } @{ $pass->{violations} };
ok( $damaged, 'the damaged card is reported' )
  or die "nothing to say anything about\n";

# --- it says which byte, and where -----------------------------------------------------

like( $damaged->{detail}, qr/0xD7/i,
    'naming the byte, so a reader can judge what was lost rather than guess' );
like( $damaged->{detail}, qr/\boffset\b/i, 'and where in the file it is' );

# --- and what to run about it -----------------------------------------------------------
#
# Through the bridge, because the fix hint is what a reader of that channel acts
# on, and the generic rule that a violation carrying a card points at the card is
# exactly what was hiding the remedy.

$tira->bridge_write( store => $store, project => $root,
    violations => $pass->{violations}, settled => $pass->{settled} );
my $lines = $tira->bridge_backlog( store => $store, lines => 200 );

my ($said) = grep { /card-damaged|not valid UTF-8/ } @{$lines};
ok( $said, 'the damage reaches the bridge' );
like( $said, qr/tira\.doctor/, 'and the line names the command that repairs it' );

# --- while every other rule still points at its card ---------------------------------------
#
# The generic hint is right almost everywhere. A rule that names its own remedy
# has to beat it without replacing it.

{
    my $other = $tira->create_record( project => $root, type => 'ticket',
        title => 'Dropped in silence' )->{ref};
    $tira->record_move( project => $root, ref => $other, column => 'discard' );
    $tira->policy_add( project => $root, rule => 'discard-unexplained',
        action => 'bridge-reminder' );

    my $again = $tira->police_pass( project => $root,
        store => File::Spec->catdir( $tmp, 'police-two' ),
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    $tira->bridge_write( store => File::Spec->catdir( $tmp, 'police-two' ), project => $root,
        violations => $again->{violations}, settled => $again->{settled} );
    my $more = $tira->bridge_backlog( store => File::Spec->catdir( $tmp, 'police-two' ),
        lines => 200 );

    my ($dropped) = grep { /\Q$other\E/ } @{$more};
    ok( $dropped, 'a card discarded without a reason still reaches the bridge' );
    like( $dropped, qr/fix: d2 tira\.ticket\.show --ref \Q$other\E/,
        'and still points at its card, because that is right for every other rule' );
}

# --- and a board with nothing wrong is unchanged ---------------------------------------------

{
    my $well = File::Spec->catdir( $tmp, 'well' );
    my $healthy = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );
    $healthy->project_new(
        name => 'Healthy', dir => $well, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'HYS', epic_prefix => 'HYE', ticket_prefix => 'HYT',
    );
    $healthy->create_record( project => $well, type => 'ticket', title => 'Nothing wrong' );

    my $quiet = $healthy->police_pass( project => $well,
        store => File::Spec->catdir( $tmp, 'police-quiet' ),
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is_deeply( [ grep { $_->{rule} eq 'card-damaged' } @{ $quiet->{violations} } ], [],
        'a board with nothing wrong says nothing about damage' );
}

done_testing;

__END__

=head1 NAME

193-a-violation-that-names-the-remedy.t - card-damaged says where and what to run

=head1 DESCRIPTION

C<card-damaged> said a byte had been substituted while reading and nothing about
which byte or where, and its fix hint was C<d2 tira.ticket.show> - a viewer,
which changes nothing about the byte. It now names the byte and its offset, and
points at C<tira.doctor>, which has repaired exactly this since 1.94.

Every other violation carrying a card still points at the card, because that is
right for every rule that does not have a command of its own.

=cut
