#!/usr/bin/env perl
# What is outstanding, and when that was last true.
#
# Three cards, one output. His question was the first of them: "why the action
# all log only? this outstanding command is act-on-it when the agent look at
# this. they won't act on it but just log only. whats the point to have a
# outstanding list?" - TKT-313. The list mixes findings the board chases with
# findings it declared log-only, and both come back tone 'note', so the one
# signal a reader sees does not carry the difference.
#
# TKT-378 is the other half, and it cost a whole day of small confusions.
# tira.police.outstanding reads the violation ledger, and only a police pass
# writes it - so the answer is as of the last pass and says so nowhere. Measured:
# fix the fault, ask again with no pass in between, and the count does not move.
# The instruction an agent is given for clearing violations ends "then run
# tira.police.outstanding again and confirm that violation is gone", which
# cannot work.
#
# Worse than merely stale: an empty answer and a board nobody has ever policed
# print the same thing, so "nothing is wrong" and "nothing has been checked" are
# indistinguishable at exactly the moment that matters.
#
# The shape is fixed by a caller. -o json is piped by that instruction, so it
# stays a bare list - the CLI contract says -o json is the full underlying
# payload and the default is a human-readable summary, and TKT-354 is already
# open about tira.next returning a dict when work waits and a list when it does
# not. This adds nothing to the payload and everything to the summary.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-18T12:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Asked', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'AKS', epic_prefix => 'AKE', ticket_prefix => 'AKT',
);

sub run {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => 'police.outstanding', tira => $tira,
                argv => [ '--store', $store, @argv ] );
        };
    };
    return ( $status, $out . $err );
}

# --- an empty answer says the board has been looked at ------------------------------
#
# Asserted first, and it is the case that reads worst today: with no findings
# the output is "[0]:" - which is also exactly what a board nobody has ever
# policed prints.

{
    my ( $status, $said ) = run();
    is( $status, 0, 'asking an unpolluted board is not an error' );
    like( $said, qr/never|no pass|not been/i,
        'and an answer from a board nobody has policed says so, rather than showing an empty list' );
}

# --- two findings, one chased and one only recorded ----------------------------------

$tira->policy_add( project => $root, rule => 'card-unassigned', action => 'log-only' );
$tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Breaks both at once', priority => 3 );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );

$now = '2026-08-18T12:05:00Z';
$tira->police_pass( project => $root, store => $store, world => {} );

{
    my ( undef, $said ) = run();
    like( $said, qr/card-unassigned/, 'the log-only finding is listed' );
    like( $said, qr/orphan-card/,     'and the chased one' );

    # A summary rather than the ledger dumped as toon. The first draft of this
    # test asserted that the words "log-only" and the timestamp appeared, and it
    # PASSED against the unchanged command - because the raw dump contains an
    # action field and a last_seen on every row. Asserting the absence of the
    # machine fields is what tells a summary from a dump.
    unlike( $said, qr/first_seen/,
        'the default output is a summary, not the ledger rendered as toon' );

    # His question, answered where a reader is looking rather than in a field
    # they must know to read. Both findings come back tone 'note' today, so tone
    # cannot be the thing that carries it.
    like( $said, qr/only recorded|not chased|recorded only/i,
        'and it says which of them the board decided only to record' );
}

# --- and it says when it was last true ------------------------------------------------

{
    my ( undef, $said ) = run();
    like( $said, qr/as of .*12:05/,
        'the answer states the time of the pass it reflects, once, rather than per row' );
}

# --- fixing the fault does not change the answer until a pass runs ---------------------
#
# The measured behaviour that breaks the confirm step. This does not change it -
# a read command that quietly ran a pass would turn every look into a write, move
# the escalation counts and put lines on the bridge because somebody asked a
# question. It makes it visible instead.

{
    $now = '2026-08-18T12:30:00Z';
    $tira->record_update( project => $root, ref => $card->{ref},
        author => 'claude', assignee => 'claude' );

    my ( undef, $said ) = run();
    like( $said, qr/as of .*12:05/,
        'after a fix with no pass, the answer still says 12:05 - so a reader can see it is not about now' );

    my $before = $tira->police_outstanding( store => $store );
    $tira->police_pass( project => $root, store => $store, world => {} );
    my $after = $tira->police_outstanding( store => $store );
    cmp_ok( scalar @{$after}, '<', scalar @{$before},
        'and a pass is what moves it, which is why the age is worth printing' );
}

# --- the payload keeps its shape --------------------------------------------------------
#
# The clear-violations instruction pipes `-o json` and indexes the result. A
# wrapper carrying the age would break it silently, which is the fault TKT-354
# reports about tira.next from the other direction.

{
    my ( undef, $json ) = run( '-o', 'json' );
    my $payload = eval { Tira::json_object()->decode($json) };
    is( ref $payload, 'ARRAY', '-o json is still a bare list' )
      or diag($json);
    for my $row ( @{ $payload || [] } ) {
        ok( exists $row->{rule} && exists $row->{action},
            'and every row still carries its rule and its action' );
    }
}

# --- proved by taking the age away --------------------------------------------------------

{
    my ( undef, $with ) = run();
    like( $with, qr/as of /, 'the age is shown' );

    no warnings 'redefine';
    local *Tira::police_outstanding_taken_at = sub { return undef };

    my ( undef, $without ) = run();

    # The subject established before it is denied: an empty answer would satisfy
    # any unlike, so a crashed command would read as a passing assertion. t/147
    # exists to catch exactly that and caught this.
    like( $without, qr/outstanding/,
        'the command still answers when the time is unavailable' );
    unlike( $without, qr/as of .*12:0?5/,
        'and without it a board fixed half an hour ago reads exactly like one that was never checked' );
}

done_testing;

__END__

=head1 NAME

268-an-answer-that-says-when-it-was-taken.t - TKT-313 and TKT-378

=head1 DESCRIPTION

C<tira.police.outstanding> answers from the violation ledger, which only a police
pass writes. The answer is therefore as of the last pass, and said so nowhere -
so the confirm step of the clear-violations loop could not work, and an empty
answer was indistinguishable from a board nobody had ever policed.

It also listed findings the board declared C<log-only> beside the ones it
chases, with both carrying tone C<note>.

Both are shown in the default summary. C<-o json> keeps its bare-list shape,
because the instruction that drives this loop pipes it.

=cut
