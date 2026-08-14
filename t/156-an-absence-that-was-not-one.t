#!/usr/bin/env perl
# An absence found by search is a real absence.
#
# mt5-ai searched for a figure, found nothing, and published that it "appears
# nowhere in M5T-244". It had been in that card's gate records the whole time.
# Their words: an absence proven by an instrument that cannot see two thirds of
# the record is not an absence, and nothing in the output says which parts were
# searched.
#
# Reproducing it showed the instrument sees rather less than a third. The
# haystack was the ref, the title, the description and the questions. Not the
# problem statement, not the key details, not what a solution needs, not the
# acceptance criteria, not the test steps, not the deliverables, not the scope,
# not the comments, not the gates, not the evidence. On a board where every
# card's substance is in the structured fields - which is what the rules that
# ship with Tira ask for - search reached the title and almost nothing else.
#
# Their first suggestion is the one taken: put the gates and the evidence in the
# corpus, because they are append-only observations and on a finished card they
# hold nearly all the measured content. Their second, saying which parts were
# searched, becomes unnecessary once the answer is "the card".
#
# Both search paths - the indexed one and the one that reads the files - go
# through this single function, so there is one decision here and not two.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-14T10:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Findable', dir => $root, members => ['michael'],
    columns => ['backlog, done'],
    sow_prefix => 'FNS', epic_prefix => 'FNE', ticket_prefix => 'FNT',
);

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Throughput under load',
    description => 'what it said at planning' );

$tira->record_update( project => $root, ref => $card->{ref},
    problem_or_feature => 'the drain collapses under a burst',
    solution_needed    => 'widen the drain',
    key_details        => ['the collapse is in the queue drain'],
    deliverables       => ['a drain that absorbs a burst'],
    acceptance         => ['a burst of four hundred is absorbed'],
    test_steps         => ['send four hundred at once'],
    bdd                => ['Given a burst, When it arrives, Then it is absorbed'],
    atdd               => ['the drain holds'],
    scope_in           => ['the drain'],
    scope_out          => ['the producer'],
    labels             => ['throughput'],
);
$tira->comment_add( project => $root, ref => $card->{ref}, author => 'michael',
    text => 'he sent a screenshot of the drain stalling' );
$tira->gate_add( project => $root, ref => $card->{ref}, author => 'michael',
    gate => 'the measurement', result => 'pass',
    details => 'throughput settled at 3/month under load' );
$tira->evidence_add( project => $root, ref => $card->{ref}, author => 'michael',
    summary => 'peak was 9/month on the rig' );
$tira->checklist_add( project => $root, ref => $card->{ref},
    item => 'drain the queue twice', status => 'todo' );

# What passed between the owner and whoever was working the card, and a file
# somebody attached. Both are text a card carries and both are worth finding -
# and both are the kind of list that is empty on most cards, which is how a
# branch of this ends up never running.
$tira->conversation_add( project => $root, ref => $card->{ref}, author => 'michael',
    said => 'the drain is the part I care about' );
$tira->attachment_add_content( project => $root, ref => $card->{ref},
    filename => 'drain-stall.png', content => "not really a picture\n" );

sub finds {
    my ($text) = @_;
    my $found = $tira->search( project => $root, text => $text, refs_only => 1 );
    return scalar grep { ( ref $_ ? $_->{ref} : $_ ) eq $card->{ref} } @{$found};
}

# --- what was already reachable ---------------------------------------------------

ok( finds('Throughput under load'), 'the title is found, as it always was' );
ok( finds('at planning'),           'and the description' );

# --- the measured content the report was about --------------------------------------
#
# The figure that was published as absent. It was in a gate record, which is
# where a finished card keeps what was actually measured.

ok( finds('3/month'), 'a figure that appears only in a gate record is found' );
ok( finds('the measurement'), 'and the name of the gate it was recorded against' );
ok( finds('9/month'), 'and one that appears only in an evidence summary' );

# --- and everything else an agent writes on a card ------------------------------------
#
# Wider than the report knew. These are the fields the rules that ship with Tira
# require a card to have before it leaves the backlog, so a board following its
# own rules had put almost all of its content out of reach of its own search.

ok( finds('collapses under a burst'),   'the problem statement is found' );
ok( finds('widen the drain'),           'what the solution needs' );
ok( finds('queue drain'),               'the key details' );
ok( finds('absorbs a burst'),           'the deliverables' );
ok( finds('four hundred is absorbed'),  'the acceptance criteria' );
ok( finds('send four hundred at once'), 'the test steps' );
ok( finds('When it arrives'),           'the behaviour it describes' );
ok( finds('the drain holds'),           'what it must satisfy' );
ok( finds('the producer'),              'what is out of scope, which is a decision worth finding' );
ok( finds('screenshot of the drain'),   'and what somebody said in a comment' );
ok( finds('drain the queue twice'),     'and a checklist item' );

ok( finds('the part I care about'), 'what passed between the owner and the card is found' );
ok( finds('drain-stall.png'),      'and the name of a file attached to it' );

# --- while a string on no card is still absent ------------------------------------------
#
# Widening the corpus must not turn search into something that matches
# everything. An absence has to stay possible or the instrument is no better
# than before.

ok( !finds('nothing on this board says this'), 'a string nowhere on the card is still not found' );

# --- and the two ways of searching agree --------------------------------------------------
#
# One board can be searched with an index or without one. If the corpus differed
# between them, an absence would depend on whether somebody had built an index -
# which is the same fault one level down.

SKIP: {
    skip 'SQLite is not installed here', 2 if !eval { require DBD::SQLite; 1 };
    $tira->search_index( project => $root );
    ok( finds('3/month'), 'the indexed search reaches the gate record too' );
    ok( finds('queue drain'), 'and the key details, so an absence does not depend on having an index' );
}

done_testing;

__END__

=head1 NAME

156-an-absence-that-was-not-one.t - an absence found by search is a real absence

=head1 DESCRIPTION

A project searched for a figure, found nothing, and published that it appeared
nowhere on a card. It was in that card's gate records. The searchable text was
the ref, the title, the description and the questions - so the problem
statement, the key details, the acceptance criteria, the comments, the gates and
the evidence were all invisible, which on a board following Tira's own rules is
almost everything a card says.

The corpus is now the card. Both search paths share one function, so an absence
does not depend on whether an index was built, and a string on no card is still
not found.

=cut
