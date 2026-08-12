#!/usr/bin/env perl
# One board, worked both ways.
#
# Five tickets built the pieces and each proved its own against its own scratch
# board. The claim EPC-003 actually makes is about the two kinds of project
# together: that a chain works, and that a single agent is untouched. No test
# made that claim, and an epic whose children are all done is not the same as
# an epic that is done - which is the parent-ahead lie the police rule exists
# to catch, and it would have been told by the person who wrote the rule.
#
# So: one board. Worked as a single agent, asserted. Declared a chain, worked
# again, asserted. The rules that differ are exercised under both, and the ones
# that do not are asserted not to - because "this rule is unaffected" is a claim
# too, and an unchecked one is how a rule quietly starts behaving differently.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T10:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Both ways', dir => $root, members => [ 'michael', 'ada', 'grace' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'BWS', epic_prefix => 'BWE', ticket_prefix => 'BWT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

my %world = (
    branches => [], worktrees => [], processes => [], containers => [], commits => [] );

sub police {
    my (%extra) = @_;
    my $result = $tira->police_pass(
        project => $root, store => $store, world => { %world, %extra } );
    my %by_rule;
    push @{ $by_rule{ $_->{rule} } }, $_ for @{ $result->{violations} };
    return \%by_rule;
}

sub only_policies {
    my (@policies) = @_;
    for my $existing ( @{ $tira->policy_list( project => $root ) } ) {
        $tira->policy_remove( project => $root, id => $existing->{id} );
    }
    $tira->policy_add( project => $root, %{$_} ) for @policies;
    return;
}

# Three cards being worked at once, held by two agents and nobody.
my $epic = $tira->create_record( project => $root, type => 'epic', title => 'The work' );
my @cards;
for my $each ( [ 'First', 'ada' ], [ 'Second', 'grace' ], [ 'Third', undef ] ) {
    my $card = $tira->create_record( project => $root, type => 'ticket', title => $each->[0] );
    $tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $card->{ref} );
    $tira->record_update( project => $root, ref => $card->{ref}, assignee => $each->[1] )
      if defined $each->[1];
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );
    push @cards, $card;
}

# ==========================================================================
# As a single agent - which is what this board is until somebody says otherwise
# ==========================================================================

is( $tira->project_mode( project => $root ), undef,
    'a board nobody has asked has not been told which kind it is' );

# --- the limit ------------------------------------------------------------
#
# A single agent carries its number in the policy, which is what every board
# that declared this rule before today does.

only_policies( { rule => 'wip-limit', column => 'implement', max => 2, action => 'log-only' } );
my $single = police();
is( scalar @{ $single->{'wip-limit'} // [] }, 1, 'three cards past a limit of two is reported' );
like( $single->{'wip-limit'}[0]{detail}, qr/limit is 2/, 'against the policy\'s own number' );
like( $single->{'wip-limit'}[0]{detail}, qr/\(ada\).*\(grace\).*\(nobody\)/s,
    'naming who holds each, which is what makes a board-wide count readable' );

# --- the sandbox rule -----------------------------------------------------
#
# Declarable on a single-agent board and perfectly quiet on one that uses no
# work trees, which is why it is left undeclared on boards like this.

only_policies( { rule => 'card-sandbox-missing', enter => 'implement',
        sandbox => '/sandboxes', action => 'log-only' } );
is( scalar @{ police()->{'card-sandbox-missing'} // [] }, 3,
    'declared without work trees it reports every card being worked, which is why boards like this do not declare it' );

# --- the bridge -----------------------------------------------------------

only_policies( { rule => 'card-full-details', enter => 'implement', action => 'bridge-reminder' } );
my $found = $tira->police_pass( project => $root, store => $store, world => {%world} );
$tira->bridge_write( store => $store, project => $root, violations => $found->{violations} );

my $ada = $tira->bridge_backlog( store => $store, agent => 'ada', lines => 50 );
my $everything = $tira->bridge_backlog( store => $store, lines => 50 );
ok( scalar @{$ada} < scalar @{$everything},
    'one agent naming itself hears less than the whole board, which is the point of the filter' );
ok( ( grep { /for ada/ } @{$ada} ), 'and hears its own' );
ok( !( grep { /for grace/ } @{$ada} ), 'and not somebody else\'s' );

# ==========================================================================
# The same board, declared a chain
# ==========================================================================

is( $tira->project_mode( project => $root, mode => 'chain' ), 'chain',
    'the same board can say it is worked by a chain' );

# --- the limit, from the project ------------------------------------------
#
# Not because the rule counts differently - he was clear it counts the board
# either way - but because the number that is right for one agent is not the
# number that is right for six.

$tira->project_limit( project => $root, max => 6 );
only_policies( { rule => 'wip-limit', column => 'implement', action => 'log-only' } );
is( scalar @{ police()->{'wip-limit'} // [] }, 0,
    'a chain sets a number that fits it, and the same three cards are within it' );

$tira->project_limit( project => $root, max => 1 );
my $tight = police();
is( scalar @{ $tight->{'wip-limit'} // [] }, 1, 'lowering it fires again, on the same cards' );
like( $tight->{'wip-limit'}[0]{detail}, qr/limit is 1/,
    'against the project\'s number now, with no policy touched' );

# --- the sandbox rule, made real ------------------------------------------

only_policies( { rule => 'card-sandbox-missing', enter => 'implement',
        sandbox => '/sandboxes', action => 'log-only' } );
for my $card (@cards) {
    $tira->record_update( project => $root, ref => $card->{ref},
        sandbox => "/sandboxes/$card->{ref}" );
}
my @trees = map { "/sandboxes/$_->{ref}" } @cards;
my @branches = map { $_->{ref} } @cards;
is( scalar @{ police( branches => \@branches, worktrees => \@trees )->{'card-sandbox-missing'} // [] },
    0, 'a chain that gives every card a work tree and records it satisfies the rule' );

$tira->record_update( project => $root, ref => $cards[1]{ref}, sandbox => '' );
my $lost = police( branches => \@branches, worktrees => \@trees );
is( scalar @{ $lost->{'card-sandbox-missing'} // [] }, 1, 'and one card that stopped claiming its tree is caught' );
like( $lost->{'card-sandbox-missing'}[0]{detail}, qr/not recorded on the card/, 'by name' );
$tira->record_update( project => $root, ref => $cards[1]{ref},
    sandbox => "/sandboxes/$cards[1]{ref}" );

# --- the bridge, read at the top ------------------------------------------

only_policies( { rule => 'card-full-details', enter => 'implement', action => 'bridge-reminder' } );
my $core = $tira->bridge_backlog( store => $store, lines => 50 );
ok( ( grep { /via \Q$epic->{ref}\E/ } @{$core} ),
    'the core agent, naming nobody, is told the way down to each card' );
ok( ( grep { /for ada/ } @{$core} ), 'and who each one belongs to, so it can walk it there' );

# ==========================================================================
# What did not change
# ==========================================================================
#
# "This rule is unaffected" is a claim too, and an unchecked one is how a rule
# quietly starts behaving differently.

for my $unchanged (
    { rule => 'card-full-details', enter => 'implement', action => 'log-only' },
    { rule => 'gate-missing', column => 'done', action => 'log-only' },
    { rule => 'discard-unexplained', action => 'log-only' },
    { rule => 'parent-ahead-of-children', action => 'log-only' },
) {
    only_policies($unchanged);
    $tira->project_mode( project => $root, mode => 'single' );
    my $as_single = scalar @{ police()->{ $unchanged->{rule} } // [] };
    $tira->project_mode( project => $root, mode => 'chain' );
    my $as_chain = scalar @{ police()->{ $unchanged->{rule} } // [] };
    is( $as_chain, $as_single, "$unchanged->{rule} means the same thing in both" );
}

# --- and a board that was never asked -------------------------------------
#
# Every board that exists is one of these. The whole design rests on them not
# changing underneath their owners.

my $untouched = File::Spec->catdir( $tmp, 'never-asked' );
$tira->project_new(
    name => 'Never asked', dir => $untouched, members => ['michael'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'NAS', epic_prefix => 'NAE', ticket_prefix => 'NAT',
);
my $old = $tira->create_record( project => $untouched, type => 'ticket', title => 'As it always was' );
$tira->record_move( project => $untouched, ref => $old->{ref}, column => 'implement' );
$tira->policy_add( project => $untouched, rule => 'wip-limit',
    column => 'implement', max => 1, action => 'log-only' );

is( $tira->project_mode( project => $untouched ), undef, 'it was never asked' );
is( $tira->project_limit( project => $untouched ), undef, 'and never given a number' );
my $before = $tira->police_pass(
    project => $untouched, store => File::Spec->catdir( $tmp, 'old-state' ), world => {%world} );
is( scalar @{ $before->{violations} }, 0,
    'and behaves exactly as it always has, with its policy carrying its own number' );

done_testing();

__END__

=head1 NAME

115-one-board-both-ways.t - one board, worked as a single agent and as a chain

=head1 DESCRIPTION

Five tickets built the pieces and each proved its own in isolation. The claim
the epic makes is about the two kinds of project together, and nothing made it.
An epic whose children are all done is not the same as an epic that is done.

So one board is worked both ways: the rules that differ are exercised under
each, the rules that do not are asserted not to, and a board that was never
asked which kind it is - which is every board that exists - is proved
unchanged.

=cut
