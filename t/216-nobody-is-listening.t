#!/usr/bin/env perl
# The rule for nobody listening cannot wait for a fifth telling.
#
# The owner saw two cards in a column that allows one and asked whether the
# limit was broken. It was not: police raised it and repeated it. Nothing
# reached me because its action is bridge-reminder and no reader was attached.
#
# Police detected that too - bridge-unread - and delivered it down the bridge.
# So the one rule whose premise is that the bridge is not being read spoke into
# the bridge. Its other route is the owner's terminal, which opens on the pass
# where a violation has been seen five times; that threshold is deliberate and
# right for every rule that has a working channel in the meantime. This one
# does not. Measured on the real board: sixty-four minutes, four tellings, tone
# urgent, delivered to neither party, and it closed only because the owner
# happened to tell me to attach a reader for an unrelated reason.
#
# So the wait is the fault, not the delivery. This rule escalates on its first
# telling.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $store = File::Spec->catdir( $tmp, 'store' );
my $now   = '2026-08-15T09:00:00Z';

my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Unheard', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'UHS', epic_prefix => 'UHE', ticket_prefix => 'UHT',
);

# Something for police to write about, so the bridge is not empty - an empty
# bridge is not unread, and sending anybody to look at one is how they learn to
# stop looking.
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A bare card, so there is something on the bridge' );
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );
$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'bridge-unread',
    age => '1m', action => 'bridge-reminder' );

# --- two passes, and nobody has read anything -----------------------------

my @terminal;
my $unread_on_bridge = 0;

for my $minute ( 0 .. 1 ) {
    $now = sprintf '2026-08-15T09:%02d:00Z', 10 + $minute * 10;
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    $tira->bridge_write( store => $store, project => $root,
        violations => $pass->{violations}, settled => $pass->{settled} );
    push @terminal, @{ $pass->{terminal} };
    $unread_on_bridge++
      for grep { ( $_->{rule} // '' ) eq 'bridge-unread' } @{ $pass->{violations} };
}

# The finding is real and police is making it.
ok( $unread_on_bridge, 'police finds that nobody is reading the bridge' );

# And it reaches the owner without waiting to be told four more times. Asserted
# on the terminal lines themselves, because a violation raised and a violation
# delivered are the two different things this card is about.
my @said = grep { /bridge/i } @terminal;
ok( scalar @said,
    'and says so on the owner terminal, rather than only into the channel it is reporting unread' );

# --- while every other rule keeps the wait it was given -------------------
#
# The threshold is deliberate: said once, at the fifth telling, so escalation
# does not become the noise it exists to rise above. Only the rule whose own
# channel is the thing being reported is exempt, and a fix that made everything
# escalate at once would be a louder bug than the one it replaced.

my @others = grep { !/bridge/i } @terminal;
is( scalar @others, 0,
    'and no other rule is escalated early to achieve it' );

done_testing;

__END__

=head1 NAME

216-nobody-is-listening.t - the rule for an unread bridge cannot wait

=head1 DESCRIPTION

C<bridge-unread> reports that nobody is reading the bridge, and was delivered
down the bridge. Its other route is the owner's terminal, which opens once a
violation has been seen five times - a wait that is right for every rule with a
working channel in the meantime, and wrong for the one rule whose channel is
the thing being reported.

Measured on the real board before this was written: four tellings in
sixty-four minutes, at urgent, delivered to nobody.

This rule escalates on its first telling. Every other rule keeps the threshold
it had, which the last assertion holds.

=cut
