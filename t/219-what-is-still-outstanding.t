#!/usr/bin/env perl
# What is still outstanding, asked as a question.
#
# The owner asked why I do not follow up on the bridge. The measurement was
# worse than the question: VIO-0002 was raised at 20:19, escalated note to
# warning to urgent to critical over two and a half hours, and I read it four
# times and wrote nothing. Two findings were open on the board and I read that
# set for the first time only when asked.
#
# The bridge is a stream and is right to be one, but a stream can only be read
# from where you joined it. It replays everything on connect - 47 lines that
# night - and repeats each finding as it climbs its ladder, so two outstanding
# things sit buried in dozens of lines of history and repetition. The
# enforcement log is flat: every row is something that happened, and nothing on
# a row says whether it is still true. Police itself knows exactly, in the open
# section of its own ledger, and that was private.
#
# So the question could not be asked, and therefore was not. The answer had to
# depend on somebody remembering, which is the thing this subsystem exists to
# remove.

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
    name => 'Outstanding', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'OTS', epic_prefix => 'OTE', ticket_prefix => 'OTT',
);

# Two cards and two rules, so one finding can be settled while the other stands
# and the answer is a difference rather than an emptying.
my $stays = $tira->create_record( project => $root, type => 'ticket',
    title => 'The one that stays wrong' );
my $fixed = $tira->create_record( project => $root, type => 'ticket',
    title => 'The one that gets fixed' );
$tira->record_move(author => 'claude',  project => $root, ref => $_->{ref}, column => 'implement' )
  for $stays, $fixed;

$tira->policy_add( project => $root, rule => 'card-unassigned',
    action => 'bridge-reminder' );

# Raised, and raised again, so one of them has a history to be old about.
for my $minute ( 0, 30, 60 ) {
    $now = sprintf '2026-08-15T09:%02d:00Z', $minute;
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    $tira->bridge_write( store => $store, project => $root,
        violations => $pass->{violations}, settled => $pass->{settled} );
}

# --- what is still true ----------------------------------------------------

my $open = $tira->police_outstanding( store => $store );
is( ref $open, 'ARRAY', 'the outstanding set can be asked for' );
is( scalar @{$open}, 2, 'and holds one entry per finding still true, not one per telling' );

my ($first) = grep { ( $_->{ref} // '' ) eq $stays->{ref} } @{$open};
ok( $first, 'naming the card it is about' );
is( $first->{rule}, 'card-unassigned', 'and the rule that raised it' );
is( $first->{seen}, 3, 'and how many times it has been said, which is what a ladder is' );
ok( $first->{first_seen}, 'and when it started' );
like( $first->{tone}, qr/\A(?:note|warning|urgent|critical)\z/,
    'and how loud it has become, because an hour-old finding reads differently from a new one' );

# --- and what has stopped being true ---------------------------------------
#
# The whole point. A finding that was dealt with must leave the list, or the
# list becomes another thing that repeats itself and is skimmed.

$tira->assignment_set( project => $root, ref => $fixed->{ref}, people => ['claude'] );
$now = '2026-08-15T10:30:00Z';
my $after = $tira->police_pass( project => $root, store => $store, world => {} );
$tira->bridge_write( store => $store, project => $root,
    violations => $after->{violations}, settled => $after->{settled} );

my $remaining = $tira->police_outstanding( store => $store );
is( scalar @{$remaining}, 1, 'a finding that was dealt with leaves the list' );
is( $remaining->[0]{ref}, $stays->{ref}, 'and the one nobody dealt with is still on it' );

# --- asked without restarting anything -------------------------------------
#
# The bridge already knows this and says so in its replay header, which is why
# it was the only way to find out. Reading it there means reconnecting, and a
# question you have to restart something to ask is one you stop asking.

my $again = $tira->police_outstanding( store => $store );
is_deeply( $again, $remaining, 'and asking twice does not change the answer' );

# --- and asked the way somebody asks it ------------------------------------
#
# Through the command, because a method nobody can reach from a terminal
# answers a question nobody can ask. The whole card is that the question was
# unaskable.

{
    require Tira::CLI;
    my $out = '';
    open my $capture, '>', \$out or die $!;
    {
        local *STDOUT = $capture;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
            command => 'police.outstanding', tira => $tira,
            argv => [ '--store', $store, '-o', 'json' ] ) };
    }

    # non-empty is the whole claim: a precondition for the two below, which
    # would pass against a command that printed nothing at all.
    like( $out, qr/\S/, 'the command answers' );
    like( $out, qr/\Q$stays->{ref}\E/, 'naming the finding still outstanding' );
    unlike( $out, qr/\Q$fixed->{ref}\E/,
        'and not the one that was dealt with, which is what makes the list worth reading' );
}

done_testing;

__END__

=head1 NAME

219-what-is-still-outstanding.t - the question that could not be asked

=head1 DESCRIPTION

The bridge is a stream and the enforcement log is flat, so neither answers
"what have I not dealt with". Police's own ledger knows, and it was private.

One entry per finding still true - not one per telling - carrying the card, the
rule, how many times it has been said, when it started and how loud it has
become. A finding that was dealt with leaves the list, which is the half that
makes it worth reading.

=cut
