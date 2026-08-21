#!/usr/bin/env perl
# A bridge line says what happened, and names nobody.
#
# His words: "on the bridge, each line of message show 'for <who>' - it never
# guessed right, and when wrong the agent ignores it instead of inspecting it
# first. can you remove that part of the line."
#
# The failure mode is the one that matters. A wrong addressee does not merely
# fail to help: it gives every other reader a reason to skip the line. So a
# guess that was right most of the time would still cost more than it saves,
# because the cost lands entirely on the times it is wrong.
#
# And it is a guess. The addressee is inferred from the card - the assignee if
# there is one, a placeholder if there is not - which is why this board's own
# bridge read "for claude" and "for anyone" on lines about cards nobody was
# assigned to.
#
# What is NOT changed here, deliberately: which reader a line is delivered to,
# and which violations each STILL OPEN tail counts. Removing the words is what
# he asked for. Changing the routing would change what an agent is told and he
# could not see it happen.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $tira  = Tira->new( clock => sub {'2026-08-17T11:00:00Z'} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Unaddressed', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'UAS', epic_prefix => 'UAE', ticket_prefix => 'UAT',
);
$tira->policy_add( project => $root, rule => 'card-unassigned',
    action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'orphan-card',
    action => 'bridge-reminder' );

my $mine = $tira->create_record( project => $root, type => 'ticket',
    title => 'Assigned to somebody', priority => 3, assignee => 'claude' );
$tira->record_move(author => 'claude',  project => $root, ref => $mine->{ref}, column => 'implement' );

my $nobodys = $tira->create_record( project => $root, type => 'ticket',
    title => 'Assigned to nobody at all', priority => 3 );
$tira->record_move(author => 'claude',  project => $root, ref => $nobodys->{ref}, column => 'implement' );

sub bridge {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    $tira->bridge_write( store => $store, project => $root,
        violations => $pass->{violations}, settled => $pass->{settled} );
    return $tira->bridge_backlog( store => $store, lines => 500 );
}

# --- a card with an assignee, and a card with none -----------------------------
#
# Both, because the placeholder was as wrong as the name: "for anyone" reads as
# somebody else's problem just as readily.

{
    my $lines = bridge();
    cmp_ok( scalar @{$lines}, '>', 0, 'the bridge has something on it' );

    my @addressed = grep { / \| for [^|]* \| / } @{$lines};
    is_deeply( \@addressed, [], 'no line names who it is for' );

    unlike( join( '', @{$lines} ), qr/\bfor anyone\b/,
        'and none says anyone either, which read as nobody' );
}

# --- while everything that is not a guess stays -------------------------------
#
# The rule, the card, the detail and the way to the card are all facts. Only the
# addressee was inferred, and only the addressee goes.

{
    my $said = join '', @{ bridge() };
    like( $said, qr/card-unassigned/, 'the rule is still named' );
    like( $said, qr/\Q$nobodys->{ref}\E/, 'and the card' );
    like( $said, qr/VIO-\d+/, 'and the reference it can be followed by' );
    like( $said, qr/fix: /, 'and what to run next' );
}

# --- the summary too, which is where it was most misleading --------------------
#
# The STILL OPEN tail was split by audience and addressed the same way, so a
# reader whose name was not on it had a reason to skip the one line whose whole
# job is to stop things being forgotten.

{
    my @tails = grep { /STILL OPEN/ } @{ bridge() };
    cmp_ok( scalar @tails, '>', 0, 'the tail that lists what is still open is there' );

    is_deeply( [ grep { / \| for / } @tails ], [],
        'and it names nobody' );
    like( join( '', @tails ), qr/outstanding/,
        'while still saying what is outstanding' );
}

# --- proved by putting the addressee back --------------------------------------

{
    my $said = join '', @{ bridge() };
    unlike( $said, qr/ \| for /, 'nothing is addressed' );

    no warnings 'redefine';
    local *Tira::_bridge_audience = sub {
        my ( $self, $who ) = @_;
        return ( 'for ' . ( ( $who // '' ) ne '' ? $who : 'anyone' ) );
    };

    # A fresh card, because the bridge says a violation once: replaying the
    # same pass writes nothing, so with no new fault to report the addressee
    # would appear to have stayed gone.
    my $fresh = $tira->create_record( project => $root, type => 'ticket',
        title => 'Raised so there is something new to say', priority => 3 );
    $tira->record_move(author => 'claude',  project => $root, ref => $fresh->{ref}, column => 'implement' );

    my $again = join '', @{ bridge() };
    like( $again, qr/ \| for /,
        'and putting it back addresses them again, which is what he was reading' );
}

done_testing;

__END__

=head1 NAME

258-a-line-addressed-to-nobody.t - the addressee a bridge line was guessing at

=head1 DESCRIPTION

Every bridge line carried C<for E<lt>whoE<gt>>, inferred from the card rather
than known. A wrong addressee does not merely fail to help - it gives every
other reader a reason to skip the line, which is what he watched happen.

The words are gone. The rule, the card, the detail, the reference and the fix
all stay, because none of them was a guess; and which reader a line reaches is
deliberately untouched.

=cut
