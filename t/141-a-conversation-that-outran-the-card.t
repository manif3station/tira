#!/usr/bin/env perl
# A card that has been talked about since it was last written down.
#
# A card gathers its real content in comments. Somebody pastes evidence, answers
# a question, corrects an assumption - and the card's own details go on saying
# what they said when it was raised. The board then carries two stories on one
# card: the structured fields an agent reads, and a conversation nobody re-reads.
#
# TKT-099 was the example that started this. He pasted five bridge lines as a
# comment; they were the best evidence on the card, and the details did not know
# about them until he asked twice.
#
# He settled what counts as having dealt with it, and it needed no new field:
# "when you leave comments, you can see it in the work log. Everything can be
# seen in the work log. After leaving a comment, you can see whether the card
# was updated; if not, police speaks up."
#
# So the rule compares two things the work log already records: the newest
# comment, and the newest change to the card. If the comment is later, the
# conversation has outrun the card.
#
# I had asked whether an unrelated edit - a due date, say - should count as
# having folded the conversation in, since it would silence the reminder. He
# accepted that it does. It is simpler, it needs no command an agent could
# forget to run, and the alternative was a marker somebody has to remember.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-13T23:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Two stories', dir => $root, members => [ 'michael', 'ada' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'TSS', epic_prefix => 'TSE', ticket_prefix => 'TST',
);
my $store = File::Spec->catdir( $tmp, 'police' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Talked about' );
$tira->record_update( author => 'michael', project => $root, ref => $card->{ref},
    description => 'what it said when it was raised' );

sub outrun {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq 'conversation-not-folded' } @{ $pass->{violations} } ];
}

# --- a board that has not asked hears nothing ------------------------------------

$now = '2026-08-13T23:01:00Z';
$tira->comment_add( project => $root, ref => $card->{ref}, author => 'michael',
    text => 'Look at this example, it is the best evidence on the card' );
is( scalar @{ outrun() }, 0, 'a board that has not declared the rule hears nothing' );

$tira->policy_add( project => $root, rule => 'conversation-not-folded',
    action => 'bridge-reminder' );

# --- the conversation has outrun the card ------------------------------------------

$now = '2026-08-13T23:02:00Z';
my $found = outrun();
is( scalar @{$found}, 1, 'a card talked about since it was last written down is reported' );
is( $found->[0]{ref}, $card->{ref}, 'naming the card' );
like( $found->[0]{detail}, qr/comment/i, 'and saying what has happened to it' );

# --- writing it down stops it --------------------------------------------------------
#
# Any change to the card counts. That is his answer, and it means there is no
# command to remember and nothing to mark by hand.

$now = '2026-08-13T23:03:00Z';
$tira->record_update( author => 'michael', project => $root, ref => $card->{ref},
    description => 'what it said when it was raised, and what the comment added' );
$now = '2026-08-13T23:04:00Z';
is( scalar @{ outrun() }, 0, 'once the card is written down again it is not reported' );

# --- and a further comment starts it again ---------------------------------------------

$now = '2026-08-13T23:05:00Z';
$tira->comment_add( project => $root, ref => $card->{ref}, author => 'michael',
    text => 'One more thing' );
$now = '2026-08-13T23:06:00Z';
is( scalar @{ outrun() }, 1,
    'a comment after that is reported again, because the card has moved on since' );

# --- a card nobody has commented on is never reported ------------------------------------
#
# Most cards on a board have no conversation at all, and a rule that reported
# them would be noise on every pass.

my $quiet = $tira->create_record( project => $root, type => 'ticket', title => 'Nobody has said anything' );
$now = '2026-08-13T23:07:00Z';
is( scalar( grep { $_->{ref} eq $quiet->{ref} } @{ outrun() } ), 0,
    'a card with no conversation is never reported' );

# --- and it can be put down for the card being worked hard --------------------------------
#
# The other half of what he asked for, which shipped in 1.48. A card collecting
# comments faster than anybody can fold them is exactly the case this rule would
# otherwise chase all afternoon.

$now = '2026-08-13T23:08:00Z';
$tira->rule_suspend( project => $root, store => $store,
    rule => 'conversation-not-folded', ref => $card->{ref},
    seconds => 300, reason => 'folding a long conversation in one pass' );
$now = '2026-08-13T23:09:00Z';
is( scalar( grep { $_->{ref} eq $card->{ref} } @{ outrun() } ), 0,
    'the rule put down for that card says nothing about it' );

$now = '2026-08-13T23:15:00Z';
is( scalar( grep { $_->{ref} eq $card->{ref} } @{ outrun() } ), 1,
    'and comes back when the time runs out, with the conversation still unfolded' );

# --- and it takes no age ----------------------------------------------------------
#
# A comment that has not been folded in is not neglect that ripens - the card is
# already carrying two stories - and the quiet ladder is what keeps it from
# being said twice a minute. An age here would be accepted, ignored and
# believed, so it is refused.
#
# This assertion was missing for a day. The rule refused correctly the whole
# time and nothing would have noticed if it stopped, which is why every declared
# refusal is now checked for having a test of its own in t/79.

my $refused = !eval {
    $tira->policy_add( project => $root, rule => 'conversation-not-folded',
        age => '10m', action => 'bridge-reminder' );
    1;
};
ok( $refused, 'an age on this rule is refused rather than quietly ignored' );
like( $@, qr/takes no --age/, 'and says so in the words somebody typing it would read' );

done_testing;

__END__

=head1 NAME

141-a-conversation-that-outran-the-card.t - a card talked about since it was written down

=head1 DESCRIPTION

A card gathers its real content in comments while its own details go on saying
what they said when it was raised, so the board carries two stories on one card.

C<conversation-not-folded> compares the newest comment against the newest change
to the card - both of which the work log already records - and reports the card
when the conversation is the later of the two. Any change to the card settles
it, which is what the owner chose: no marker to remember and no command to
forget. A card with no conversation is never reported, and the rule can be put
down per card while a long conversation is being folded in.

=cut
