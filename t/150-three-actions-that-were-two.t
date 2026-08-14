#!/usr/bin/env perl
# Three policy actions that mean three things.
#
# A policy declares one of three actions, and only one of them was ever read.
# The engine compares action against bridge-reminder twice and nowhere else;
# what reaches the owner's terminal was decided by escalation alone. So a rule
# set to log-only appeared on his terminal exactly like one set to
# bridge-reminder, and print-reminder did nothing that log-only did not.
#
# The policies guide states it as a table: print-reminder goes to the owner's
# police terminal, log-only is "recorded, said to nobody", for when you are
# tuning a rule and do not want the noise yet. The second row was not true, and
# it was untrue in exactly the situation it exists for - you reach for log-only
# to stop the noise, and it puts the rule on his terminal anyway.
#
# The engine's own comment beside the bridge filter describes the intended
# design: log-only "is being tuned and stays out of the way", print-reminder
# "belongs in the owner's terminal instead". Nothing implemented the second half
# of it, and the comment had been sitting above the code that did not do it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-14T00:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Three actions', dir => $root, members => ['michael'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'TAS', epic_prefix => 'TAE', ticket_prefix => 'TAT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

# One card per action, same rule, declared on the card so the three cannot
# interfere with each other. Only the action differs.
my %card;
for my $action (qw(bridge-reminder print-reminder log-only)) {
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => "A bare card watched with $action" );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );
    $card{$action} = $card->{ref};
    $tira->policy_add( project => $root, rule => 'card-full-details',
        enter => 'implement', ref => $card->{ref}, action => $action );
}

# Twelve passes an hour apart, which is past the quiet ladder and past the fifth
# telling where a violation escalates. Anything that is going to reach the owner
# has reached him by the end of this.
my ( %terminal, %bridge );
for my $hour ( 0 .. 11 ) {
    $now = sprintf '2026-08-%02dT%02d:00:00Z', 14 + int( $hour / 24 ), $hour % 24;
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    $tira->bridge_write( store => $store, project => $root,
        violations => $pass->{violations}, settled => $pass->{settled} );
    for my $line ( @{ $pass->{terminal} } ) {
        for my $action ( keys %card ) {
            $terminal{$action}++ if $line =~ /\Q$card{$action}\E/;
        }
    }
}

{
    my $path = $tira->bridge_log_path( store => $store );
    open my $fh, '<:raw', $path or die "$path: $!";
    my $log = do { local $/; <$fh> };
    close $fh;
    # non-empty is the whole claim: a precondition for the counts that follow.
like( $log, qr/\S/, 'police wrote a bridge at all, so the counts below are about a real log' );
    for my $action ( keys %card ) {
        $bridge{$action} = () = $log =~ /\Q$card{$action}\E/g;
    }
}

# --- the one that goes everywhere -----------------------------------------------

ok( $bridge{'bridge-reminder'}, 'a rule set to bridge-reminder reaches the bridge' );
is( $terminal{'bridge-reminder'}, 1,
    'and reaches the owner once, when it escalates, which is unchanged' );

# --- the one that is only for him -------------------------------------------------

is( $bridge{'print-reminder'}, 0, 'a rule set to print-reminder stays off the bridge' );
is( $terminal{'print-reminder'}, 1, 'and reaches the owner, which is what it is for' );

# --- and the one that is for nobody -------------------------------------------------
#
# The whole finding. It is reached for precisely when somebody does not want the
# noise, and it made the noise on the owner's own terminal.

is( $bridge{'log-only'}, 0, 'a rule set to log-only stays off the bridge' );
is( $terminal{'log-only'}, undef,
    'and says nothing to the owner either, however many times it escalates' );

# --- while police still knows -----------------------------------------------------
#
# Recorded, said to nobody. If log-only stopped being recorded it would be an
# off switch wearing the name of a quiet one, and tuning a rule you cannot see
# the results of is not tuning.

my $log = $tira->enforcement_log( project => $root, store => $store );
ok( scalar( grep { ( $_->{ref} // '' ) eq $card{'log-only'} } @{$log} ),
    'police still records it, because a rule being tuned is one you have to be able to read back' );

# --- and what the guide says is what happens ----------------------------------------
#
# The table was right about the design and wrong about the code, which is the
# worse way round: somebody reads it, believes the second row, and gets the
# noise they used it to avoid.

my $guide = Tira::CLI::_policy_help();
like( $guide, qr/log-only.*said to nobody/,
    'the guide still promises log-only says nothing to anybody' );

done_testing;

__END__

=head1 NAME

150-three-actions-that-were-two.t - three policy actions that mean three things

=head1 DESCRIPTION

Only C<bridge-reminder> was ever read. What reached the owner's terminal was
decided by escalation alone, so C<log-only> appeared there exactly like
C<bridge-reminder>, and C<print-reminder> did nothing C<log-only> did not.

The policies guide promises C<log-only> is recorded and said to nobody, for
tuning a rule without the noise - and it made the noise on the owner's own
terminal, in the one situation it exists for. The terminal now honours the
action; police still records a log-only violation, because a rule you cannot
read back is not one you can tune.

=cut
