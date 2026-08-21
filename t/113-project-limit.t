#!/usr/bin/env perl
# How much may be in flight at once is the project's answer, not Tira's guess.
#
# Michael's answer to Q-027, 2026-08-12: the core agent raises a ticket asking
# the user what the number should be, and once it knows, Tira has a command to
# set it and to read it back. The same shape as which kind of project this is -
# the project's answer, written down, rather than a number picked for it.
#
# It has to be the project's because there is no number that is right for both
# kinds. He confirmed twice that a work-in-progress limit counts the whole
# board rather than the agent, and with one agent per card a small board-wide
# limit is the thing that stops a chain working at all. Two is sensible for one
# agent and absurd for six.
#
# So the policy stops carrying the number when the project has one, and a
# policy with neither is refused when it is declared - which is how every rule
# here treats something it cannot work without.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-12T23:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'In flight', dir => $root, members => [ 'ada', 'grace', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'IFS', epic_prefix => 'IFE', ticket_prefix => 'IFT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

# --- never asked ----------------------------------------------------------

is( $tira->project_limit( project => $root ), undef,
    'a project nobody has asked has no number, rather than one chosen for it' );

# --- set and read ---------------------------------------------------------

is( $tira->project_limit( project => $root, max => 3 ), 3,
    'a project can say how much may be in flight at once' );
is( $tira->project_limit( project => $root ), 3,
    'and says so afterwards, because it was written down rather than remembered' );

my $refused = !eval { $tira->project_limit( project => $root, max => 'lots' ); 1 };
ok( $refused, 'a limit that is not a number is refused' );
like( $@, qr/whole number of cards/, 'and says a limit is a count' );
is( $tira->project_limit( project => $root ), 3, 'and the number already there is undamaged' );

my $negative = !eval { $tira->project_limit( project => $root, max => -1 ); 1 };
ok( $negative, 'and neither is a negative one, which would mean nothing may be worked' );
like( $@, qr/whole number of cards/, 'refused for being a count, not for something else' );

is( $tira->project_limit( project => $root, max => 0 ), 0,
    'zero is allowed, because a board deliberately frozen is a real thing to say' );
$tira->project_limit( project => $root, max => 2 );

# --- a policy that does not repeat it -------------------------------------

$tira->policy_add( project => $root, rule => 'wip-limit',
    column => 'implement', action => 'log-only' );

sub working {
    my ($count) = @_;
    for my $each ( 1 .. $count ) {
        my $card = $tira->create_record( project => $root, type => 'ticket',
            title => "Card $each" );
        $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );
    }
    return;
}

sub police {
    my $result = $tira->police_pass( project => $root, store => $store, world => {
        branches => [], worktrees => [], processes => [], containers => [], commits => [] } );
    return [ grep { $_->{rule} eq 'wip-limit' } @{ $result->{violations} } ];
}

working(2);
is( scalar @{ police() }, 0, 'at the number the project set, nothing is said' );

working(1);
my $over = police();
is( scalar @{$over}, 1, 'past it, the rule fires' );
like( $over->[0]{detail}, qr/limit is 2/, 'against the number the project set, not one of its own' );
like( $over->[0]{detail}, qr/\(nobody\)/,
    'still naming who holds each card, which is what makes a board-wide count readable' );

# --- the project changes its mind -----------------------------------------
#
# Read when the rule runs rather than copied when the policy is declared. A
# number the owner raised and a rule still using the old one would be the worst
# of both: he would believe he had changed it.

$tira->project_limit( project => $root, max => 5 );
is( scalar @{ police() }, 0, 'raising the number quiets the rule, without touching the policy' );

# --- a policy that says its own number ------------------------------------
#
# Kept, because a project may want one column held tighter than the rest, and
# because every board that declared this rule before today carries its number
# in the policy.

for my $existing ( @{ $tira->policy_list( project => $root ) } ) {
    $tira->policy_remove( project => $root, id => $existing->{id} );
}
$tira->policy_add( project => $root, rule => 'wip-limit',
    column => 'implement', max => 1, action => 'log-only' );
my $tighter = police();
is( scalar @{$tighter}, 1, 'a policy carrying its own number still uses it' );
like( $tighter->[0]{detail}, qr/limit is 1/, 'and the policy wins over the project, being the narrower of the two' );

# --- neither ---------------------------------------------------------------
#
# Refused when it is declared rather than discovered later, which is how every
# other rule treats something it cannot work without.

my $bare = File::Spec->catdir( $tmp, 'no-number' );
$tira->project_new(
    name => 'Unasked', dir => $bare, members => ['ada', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'UNS', epic_prefix => 'UNE', ticket_prefix => 'UNT',
);
my $nothing = !eval {
    $tira->policy_add( project => $bare, rule => 'wip-limit',
        column => 'implement', action => 'log-only' );
    1;
};
ok( $nothing, 'a policy with no number, on a project with no number, is refused' );
like( $@, qr/max|limit/i, 'and says what is missing' );

# --- through the command an agent actually types ---------------------------

use Tira::CLI;

sub run_limit {
    my (@arguments) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        $status = do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
            command => 'project.limit', tira => $tira,
            argv => [ @arguments, '-o', 'json' ],
        ) };
    }
    return ( $out . $err, $status );
}

my ( $said, $status ) = run_limit();
is( $status, 0, 'the command answers' );
like( $said, qr/"max"\s*:\s*5/, 'with the number the project set' );

( $said, $status ) = run_limit( '--max', '7' );
is( $status, 0, 'the command sets it' );
is( $tira->project_limit( project => $root ), 7, 'which the engine agrees with' );

done_testing();

__END__

=head1 NAME

113-project-limit.t - how much may be in flight is the project's answer

=head1 DESCRIPTION

A work-in-progress limit counts the whole board, and there is no number that is
right for both a single agent and a chain of six. So the project says what it
should be, the policy stops repeating it, and the rule reads it when it runs -
a number the owner raised while the rule still used the old one would be worse
than having no number at all, because he would believe he had changed it.

A policy may still carry its own number, which is narrower and wins. A policy
with neither, on a project with neither, is refused when it is declared.

=cut
