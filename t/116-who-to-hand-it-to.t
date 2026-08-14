#!/usr/bin/env perl
# The two lines the owner reads have to say who.
#
# Found by reading SOW-002's third acceptance criterion rather than its
# children: "every place that assumed one agent is found and named, not just
# the ones that were obvious". Every child was done and that criterion was
# still unmet, because the design work had handled the places his answers
# pointed at and nobody had swept for the rest.
#
# Two turned up, and both are in what he reads with his own eyes. The terminal
# escalation line told him to "paste to the agent" as though there were one.
# The onboarding prompt told him to keep the bridge running without saying who
# should be tailing it.
#
# Naming the wrong recipient is worse than naming none, because he acts on it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-13T11:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Who', dir => $root, members => [ 'michael', 'ada' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WHS', epic_prefix => 'WHE', ticket_prefix => 'WHT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );

my $hers = $tira->create_record( project => $root, type => 'ticket', title => 'Held by ada' );
$tira->record_update( project => $root, ref => $hers->{ref}, assignee => 'ada' );
$tira->record_move( project => $root, ref => $hers->{ref}, column => 'implement' );

my $nobodys = $tira->create_record( project => $root, type => 'ticket', title => 'Held by nobody' );
$tira->record_move( project => $root, ref => $nobodys->{ref}, column => 'implement' );

# Escalation is what reaches his own terminal once a violation has been ignored
# long enough, so it is run until it does.
sub terminal {
    # Escalation happens on the pass where the count reaches the threshold and
    # never again - keeping only the last pass would find nothing, which is a
    # test that fails for a reason that has nothing to do with what it checks.
    # A day between passes. Escalation follows tellings rather than passes now,
    # and the same problem is deliberately left alone for a growing quiet
    # period before it is said again - so eight passes at one instant are one
    # telling, and nothing would ever reach his terminal.
    my @said;
    for my $day ( 1 .. 8 ) {
        $now = sprintf '2026-08-%02dT11:00:00Z', 12 + $day;
        my $pass = $tira->police_pass( project => $root, store => $store, world => {
            branches => [], worktrees => [], processes => [], containers => [], commits => [] } );
        push @said, @{ $pass->{terminal} };
    }
    return join "\n", @said;
}

my $reached = terminal();
ok( length $reached, 'a violation ignored long enough reaches his terminal' );

# --- who to hand it to ----------------------------------------------------

like( $reached, qr/\Qhand to ada\E/,
    'a card somebody holds says to hand it to them, by name' );
unlike( $reached, qr/hand to the agent\b/,
    'and never says "the agent", which names nobody and is wrong the moment there are two' );

like( $reached, qr/hand to the core agent/,
    'a card nobody holds says the core agent, which is who handles it in a chain' );

like( $reached, qr/\Qd2 tira.ticket.show --ref $hers->{ref}\E/,
    'and still carries the command he pastes, which is the point of the line' );

# --- the prompt -----------------------------------------------------------

my $single = $tira->police_prompt( project => $root );
ok( defined $single, 'a project behind on rules is given a prompt' );
like( $single, qr/tira\.policy\.bridge/, 'telling him to keep the bridge running' );
like( $single, qr/the agent working the board/,
    'and on a project nobody has declared a kind for, saying who reads it in the ordinary case' );

$tira->project_mode( project => $root, mode => 'chain' );
my $chained = $tira->police_prompt( project => $root );
like( $chained, qr/core agent/,
    'and on a chain, that it is the core agent reading it and walking each line down' );

$tira->project_mode( project => $root, mode => 'single' );
my $alone = $tira->police_prompt( project => $root );
# non-empty is the whole claim: that a prompt exists at all is the thing
# being asserted, and what it must NOT say is pinned on the next line.
like( $alone, qr/\S/,
    'a single-agent project is still given a prompt' );
unlike( $alone, qr/core agent/,
    'while a project that says it is worked by one agent is not told about a chain it does not have' );

done_testing();

__END__

=head1 NAME

116-who-to-hand-it-to.t - the two lines the owner reads have to say who

=head1 DESCRIPTION

Found by reading a statement of work's acceptance criteria rather than its
children: every child was done and "every place that assumed one agent is found
and named" was still unmet, because only the obvious places had been handled.

Two turned up, both owner-facing. The escalation line said "paste to the agent"
as though there were one; the onboarding prompt said to keep the bridge running
without saying who should be reading it. Naming the wrong recipient is worse
than naming none, because he acts on it.

=cut
