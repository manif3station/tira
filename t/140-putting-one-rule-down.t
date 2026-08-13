#!/usr/bin/env perl
# A rule can be put down for a while, without going deaf to everything else.
#
# An agent could ask police for silence about everything - police.suspend - and
# that was all. There was no way to quiet one rule while the rest kept watching,
# and no way to quiet a rule for one card.
#
# His words: "The core agent could also temporary disable the whole rule for a
# period of time with a reason not random. Once the period is passed. The police
# will resume to use the rule to apply to the cards. The agent can also
# temporary disable the rule for specific card or cards too for a period or time
# with a reason as well."
#
# Per card is the grain that matters. A card being worked hard collects comments
# faster than anybody can fold them, and if the only way through that afternoon
# is silencing the whole bridge then the escape hatch is worse than the noise it
# escapes.
#
# It looks like police.suspend because it is the same promise: an end that
# arrives by itself, and a reason nobody can skip. A silence nobody can account
# for is worse than the noise - which is already the wording police.suspend
# refuses with.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-13T22:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Quiet one thing', dir => $root, members => [ 'michael', 'ada' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'QOS', epic_prefix => 'QOE', ticket_prefix => 'QOT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

my $busy = $tira->create_record( project => $root, type => 'ticket', title => 'Worked hard' );
$tira->record_move( project => $root, ref => $busy->{ref}, column => 'implement' );
my $other = $tira->create_record( project => $root, type => 'ticket', title => 'Also bare' );
$tira->record_move( project => $root, ref => $other->{ref}, column => 'implement' );

# Two rules, so "one rule down" can be told from "police down".
$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'card-unassigned', action => 'bridge-reminder' );

sub reported {
    my ($rule) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq $rule } @{ $pass->{violations} } ];
}

# --- both rules are watching -----------------------------------------------------

ok( scalar @{ reported('card-full-details') }, 'the rule is watching to begin with' );
ok( scalar @{ reported('card-unassigned') },   'and so is the other one' );

# --- a reason is not optional ------------------------------------------------------
#
# The same refusal police.suspend already makes. A silence nobody can account
# for is worse than the noise it replaces.

my $unexplained = !eval {
    $tira->rule_suspend( project => $root, store => $store,
        rule => 'card-full-details', seconds => 300 );
    1;
};
ok( $unexplained, 'putting a rule down with no reason is refused' );
like( $@, qr/reason/i, 'and says a reason is what is missing' );

my $endless = !eval {
    $tira->rule_suspend( project => $root, store => $store,
        rule => 'card-full-details', reason => 'reading one thing to the bottom' );
    1;
};
ok( $endless, 'and so is one with no end' );

# --- the rule goes quiet, and only that rule ----------------------------------------

$tira->rule_suspend( project => $root, store => $store, rule => 'card-full-details',
    seconds => 300, reason => 'folding a long conversation into this card' );

$now = '2026-08-13T22:01:00Z';
is( scalar @{ reported('card-full-details') }, 0, 'the rule that was put down says nothing' );
ok( scalar @{ reported('card-unassigned') },
    'while every other rule carries on watching, which is the whole point' );

# --- and it comes back by itself -----------------------------------------------------

$now = '2026-08-13T22:06:00Z';
ok( scalar @{ reported('card-full-details') },
    'when the time runs out it watches again, with nothing to switch back on' );

# --- one card, not the board ---------------------------------------------------------

$tira->rule_suspend( project => $root, store => $store, rule => 'card-full-details',
    ref => $busy->{ref}, seconds => 300, reason => 'this one card is being rewritten' );

$now = '2026-08-13T22:07:00Z';
my $narrow = reported('card-full-details');
is( scalar( grep { $_->{ref} eq $busy->{ref} } @{$narrow} ), 0,
    'the card it was put down for says nothing' );
is( scalar( grep { $_->{ref} eq $other->{ref} } @{$narrow} ), 1,
    'and every other card is still reported by the same rule' );

$now = '2026-08-13T22:13:00Z';
is( scalar( grep { $_->{ref} eq $busy->{ref} } @{ reported('card-full-details') } ), 1,
    'and that card comes back too when its time runs out' );

# --- and it is all written down --------------------------------------------------------
#
# Police writes this log and nobody else may, which is what makes it worth
# reading. A quiet that leaves no trace is a quiet nobody can question.

my $log = $tira->enforcement_log( project => $root, store => $store );
my @put_down = grep { ( $_->{kind} // '' ) eq 'rule-suspension' } @{$log};
is( scalar @put_down, 2, 'both times the rule was put down are in the enforcement log' );
like( $put_down[0]{detail}, qr/card-full-details/, 'saying which rule' );
like( $put_down[0]{detail}, qr/folding a long conversation/, 'and why' );
like( $put_down[1]{detail}, qr/\Q$busy->{ref}\E/, 'and which card, when it was one card' );

# --- a rule nobody has heard of is refused ---------------------------------------------
#
# Quieting a name that is not a rule would report success and change nothing,
# which is the shape this project has spent the day removing.

my $unknown = !eval {
    $tira->rule_suspend( project => $root, store => $store, rule => 'no-such-rule',
        seconds => 60, reason => 'because' );
    1;
};
ok( $unknown, 'putting down a rule that does not exist is refused' );

done_testing;

__END__

=head1 NAME

140-putting-one-rule-down.t - a rule can be put down for a while

=head1 DESCRIPTION

An agent could quiet police entirely or not at all. One rule can now be put
down for a period, board-wide or for named cards, with a reason that is
required and recorded, and it picks itself up when the time runs out.

Per card matters: a card being worked hard collects comments faster than anybody
can fold them, and silencing the whole bridge to get through it would make the
escape hatch worse than the noise. Every other rule keeps watching throughout,
and a rule nobody has heard of is refused rather than quietly accepted.

=cut
