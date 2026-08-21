#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-11T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
sub at { $now = $_[0]; return $now }

my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Focused', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'FCS', epic_prefix => 'FCE', ticket_prefix => 'FCT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Bare' );
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );

sub sweep {
    return $tira->police_pass( project => $root, store => $store, world => {} );
}

# --- police is saying something -------------------------------------------

ok( scalar @{ sweep()->{violations} }, 'police has something to say before any of this' );

# --- asking for quiet -----------------------------------------------------

# There is no open-ended off switch. A duration is required, and enforcement
# resumes on its own - nothing to remember, nothing to undo.
ok( !eval { $tira->police_suspend( project => $root, store => $store,
        reason => 'concentrating' ); 1 },
    'suspension without a duration is refused' );
like( $@, qr/seconds/, 'and says a duration is what is missing' );

ok( !eval { $tira->police_suspend( project => $root, store => $store, seconds => 60 ); 1 },
    'and without a reason it is refused too' );
like( $@, qr/reason/, 'saying so' );

# A reason is capped rather than trimmed. Silently shortening somebody's words
# in a record meant to hold them to account is its own small dishonesty.
ok( !eval { $tira->police_suspend( project => $root, store => $store,
        seconds => 60, reason => 'x' x 501 ); 1 },
    'a reason longer than five hundred characters is refused' );
like( $@, qr/500/, 'and the limit is named rather than left to be discovered' );

# The escape hatch is the part most likely to be abused, and by the agent.
ok( !eval { $tira->police_suspend( project => $root, store => $store,
        seconds => 100_000, reason => 'a very long think' ); 1 },
    'a suspension past the ceiling is refused' );
like( $@, qr/600|ten minutes/i, 'naming the ceiling' );

my $quiet = $tira->police_suspend(
    project => $root, store => $store, seconds => 60,
    reason => 'chasing one failing test to the bottom' );
is( $quiet->{seconds}, 60, 'a proper request is accepted' );
like( $quiet->{until}, qr/\A2026-08-11T09:01:00/, 'and says when it ends' );
like( $quiet->{terminal}, qr/chasing one failing test/,
    'with something for the owner\'s terminal, so a suspension is never silent' );

# --- while it is quiet ----------------------------------------------------

at('2026-08-11T09:00:30Z');
my $during = sweep();
is_deeply( $during->{violations}, [], 'police says nothing while it is suspended' );
ok( $during->{suspended}, 'and says that is why, rather than appearing to find nothing' );

# --- and it comes back by itself ------------------------------------------

at('2026-08-11T09:01:01Z');
my $after = sweep();
ok( scalar @{ $after->{violations} }, 'enforcement resumes when the time runs out' );
ok( !$after->{suspended}, 'with nothing to remember and nothing to undo' );

# --- the enforcement log --------------------------------------------------

# The reason reaches the card's log through police, so there is no path by
# which the agent writes its own words into the record that holds it to
# account.
my $log = $tira->enforcement_log( project => $root, store => $store, ref => $card->{ref} );
ok( scalar @{$log}, 'the card has an enforcement log' );
ok( scalar( grep { ( $_->{kind} // '' ) eq 'violation' } @{$log} ),
    'carrying what police has had to say about it' );

my $everything = $tira->enforcement_log( project => $root, store => $store );
ok( scalar( grep { ( $_->{kind} // '' ) eq 'suspension' } @{$everything} ),
    'and the suspension is in the log, written on the agent\'s behalf' );
like( ( grep { ( $_->{kind} // '' ) eq 'suspension' } @{$everything} )[0]{detail},
    qr/chasing one failing test/, 'with the reason that was given' );

# There is no way for the agent to put words in this record directly.
ok( !Tira->can('enforcement_log_add'), 'there is no command to add to the log' );
ok( !Tira->can('enforcement_log_update'), 'nor to change an entry' );
ok( !Tira->can('enforcement_log_remove'), 'nor to remove one' );

# The log is police's own, so the board is untouched by any of it.
my @inside = glob File::Spec->catfile( $root, '.tira', '*enforcement*' );
is( scalar @inside, 0, 'and nothing about enforcement is written into the project' );

# --- renewing --------------------------------------------------------------

# A ceiling alone is defeated by asking again the moment each one expires, so a
# renewal inside the hour is an event in its own right.
at('2026-08-11T09:05:00Z');
my $again = $tira->police_suspend(
    project => $root, store => $store, seconds => 60, reason => 'still on it' );
ok( $again->{renewal}, 'a second suspension inside the hour is marked as a renewal' );
like( $again->{terminal}, qr/renewal/i, 'and the owner is told it is one' );
like( $again->{terminal}, qr/120s/, 'with the quiet time so far, so a pattern is visible' );

at('2026-08-11T11:30:00Z');
my $much_later = $tira->police_suspend(
    project => $root, store => $store, seconds => 60, reason => 'a fresh problem' );
ok( !$much_later->{renewal}, 'while one long afterwards is not a renewal' );

done_testing;

__END__

=head1 NAME

91-suspension.t - asking police to look away, without anybody losing sight of it

=head1 DESCRIPTION

The owner's design: the agent can quiet the bridge for a set number of seconds
so it can concentrate, and only for a set number - there is no open-ended off
switch. It requires a reason of at most five hundred characters, the owner sees
it happen in his own terminal, and the reason is written into the card's
enforcement log on the agent's behalf.

That last part is the piece worth protecting. There is no command by which the
agent writes to the enforcement log, so even its own words about its own
suspension reach the record through police. A log that exists to hold somebody
to account cannot be one they can write.

The ceiling matters because the escape hatch is the part most likely to be
abused, and by the agent. Ten minutes at a time stops one long silence; a
renewal inside the hour being an event of its own stops a chain of short ones
hiding; and the running total makes a pattern visible without ever blocking
work, because an obstacle gets worked around and this must not become one.

=cut
