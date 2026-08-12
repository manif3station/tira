#!/usr/bin/env perl
# The sandbox the card says it has, and the one that is actually there.
#
# Michael's answer to Q-025, 2026-08-12: a git work tree named after the card
# reference, made by the agent, recorded on the card. So Tira makes no work
# trees - it checks that a card being worked has one, and that the card says
# which.
#
# The recording is the part that was missing. A work tree existing somewhere on
# the machine says nothing about which card it belongs to: match it by name
# alone and a tree left behind from a card finished last week satisfies the
# rule for a card started this morning. The card saying so is what makes the
# claim checkable, and it is what his design asks for in as many words.
#
# In his design one reference names four things - the agent, its branch, its
# work tree and the card - so recording it costs a field and no thought.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-12T22:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Sandboxed', dir => $root, members => ['ada'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SBS', epic_prefix => 'SBE', ticket_prefix => 'SBT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

$tira->policy_add( project => $root, rule => 'card-sandbox-missing',
    enter => 'implement', sandbox => '/sandboxes', action => 'log-only' );

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Being worked' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );

sub police {
    my (%world) = @_;
    my $result = $tira->police_pass( project => $root, store => $store, world => {
        branches => [], worktrees => [], processes => [], containers => [], commits => [], %world } );
    return [ grep { $_->{rule} eq 'card-sandbox-missing' } @{ $result->{violations} } ];
}

my $tree = "/sandboxes/$card->{ref}";

# --- nothing at all -------------------------------------------------------

my $bare = police();
is( scalar @{$bare}, 1, 'a card being worked with no branch and no work tree is reported' );
like( $bare->[0]{detail}, qr/branch/, 'saying the branch is missing' );
like( $bare->[0]{detail}, qr/work ?tree/i, 'and the work tree' );

# --- the tree is there, and the card has not said so ----------------------
#
# The case that name-matching alone cannot tell from a satisfied one. A tree
# left behind by a card finished last week has exactly the right name.

my $unclaimed = police( branches => [ $card->{ref} ], worktrees => [$tree] );
is( scalar @{$unclaimed}, 1,
    'a work tree nobody claimed does not satisfy the rule, however well named' );
like( $unclaimed->[0]{detail}, qr/not recorded on the card/,
    'and says the card has not claimed it, which is a different fix from making one' );

# --- the card says so, and it is there ------------------------------------

$tira->record_update( project => $root, ref => $card->{ref}, sandbox => $tree );
is( $tira->record_show( project => $root, ref => $card->{ref} )->{sandbox}, $tree,
    'a card records the work tree it is being worked in' );

is( scalar @{ police( branches => [ $card->{ref} ], worktrees => [$tree] ) }, 0,
    'a card that claims its work tree, with the tree there, satisfies the rule' );

# --- the card says so, and it is not there --------------------------------
#
# Worse than never having claimed one, and said differently: something removed
# the tree while the card still believes it is working in it.

my $vanished = police( branches => [ $card->{ref} ] );
is( scalar @{$vanished}, 1, 'a claimed work tree that is not there is reported' );
like( $vanished->[0]{detail}, qr/\Q$tree\E/, 'naming the tree the card believes in' );

# --- a card that is not being worked --------------------------------------

my $waiting = $tira->create_record( project => $root, type => 'ticket', title => 'Still in the backlog' );
is( scalar @{ police( branches => [ $card->{ref} ], worktrees => [$tree] ) }, 0,
    'a card in the backlog needs no work tree, because nobody is working it' );

# --- and a project that never declared the rule ---------------------------

for my $policy ( @{ $tira->policy_list( project => $root ) } ) {
    $tira->policy_remove( project => $root, id => $policy->{id} );
}
is( scalar @{ police() }, 0,
    'a project that does not use sandboxes hears nothing about them, which is most projects' );

done_testing();

__END__

=head1 NAME

112-card-sandbox.t - the sandbox the card claims, and the one that is there

=head1 DESCRIPTION

A git work tree named after the card reference, made by the agent, recorded on
the card. Tira makes no work trees; it checks that a card being worked has one
and says which.

Recording it is what makes the claim checkable. A work tree existing on the
machine says nothing about which card it belongs to, so one left behind by a
card finished last week would otherwise satisfy the rule for a card started
this morning.

=cut
