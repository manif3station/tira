#!/usr/bin/env perl
# card-unlinked and parent-ahead-of-children both read column_roles(type)->
# {done} to decide which cards to leave alone because they have already
# shipped, and both fail the identical silent way when a board declares the
# rule without ever declaring the done role. policy_unresolved's own
# unresolved-policy detector already checks for this exact gap - but only
# by rule name, hardcoded to 'parent-ahead-of-children', so card-unlinked
# gets no warning at all. Second bug found investigating the first: the
# unresolved detail hardcodes "tira.column.roles --type ticket ..."
# regardless of the policy's own --type. TKT-437.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-23T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Unnamed', dir => $root, members => ['claude'],
    columns => ['backlog, shipped, discard'],
    sow_prefix => 'UNS', epic_prefix => 'UNE', ticket_prefix => 'UNT',
);

# --- card-unlinked alone, no done role declared -----------------------------

my $link_policy = $tira->policy_add( project => $root, rule => 'card-unlinked',
    require_link => 'blocks', action => 'bridge-reminder' );

{
    my @unresolved = grep { $_->{policy} } @{ $tira->policy_unresolved( project => $root ) };
    ok( scalar( grep { $_->{policy} eq $link_policy->{id} } @unresolved ),
        'card-unlinked with no done role declared is reported unresolved' );
    my ($mine) = grep { $_->{policy} eq $link_policy->{id} } @unresolved;
    like( $mine->{detail}, qr/cannot tell which column means finished/,
        'naming the same dependency parent-ahead-of-children already names' );
}

# --- parent-ahead-of-children keeps working exactly as before --------------

my $parent_policy = $tira->policy_add( project => $root, rule => 'parent-ahead-of-children',
    action => 'bridge-reminder' );

{
    my @unresolved = grep { $_->{policy} } @{ $tira->policy_unresolved( project => $root ) };
    ok( scalar( grep { $_->{policy} eq $link_policy->{id} } @unresolved ),
        'card-unlinked is still reported - no regression' );
    ok( scalar( grep { $_->{policy} eq $parent_policy->{id} } @unresolved ),
        'and parent-ahead-of-children is reported too - both, separately' );
    is( scalar(@unresolved), 2, 'exactly two, not one merged finding' );
}

# --- the fix command names the policy's own --type, not a hardcoded one ----

{
    my $other = File::Spec->catdir( $tmp, 'typed' );
    $tira->project_new(
        name => 'Typed', dir => $other, members => ['claude'],
        columns => ['backlog, shipped, discard'],
        sow_prefix => 'TYS', epic_prefix => 'TYE', ticket_prefix => 'TYT',
    );
    my $epic_policy = $tira->policy_add( project => $other, rule => 'parent-ahead-of-children',
        type => 'epic', action => 'bridge-reminder' );

    my @unresolved = grep { $_->{policy} } @{ $tira->policy_unresolved( project => $other ) };
    my ($mine) = grep { $_->{policy} eq $epic_policy->{id} } @unresolved;
    like( $mine->{detail}, qr/--type epic\b/,
        'a policy declared --type epic gets a fix command naming --type epic' );
    unlike( $mine->{detail}, qr/--type ticket\b/,
        'not the hardcoded --type ticket, which would leave the real policy unresolved' );
}

# --- and a board-wide policy (no --type) keeps its neutral placeholder -----

{
    my @unresolved = grep { $_->{policy} } @{ $tira->policy_unresolved( project => $root ) };
    my ($mine) = grep { $_->{policy} eq $link_policy->{id} } @unresolved;
    like( $mine->{detail}, qr/--type TYPE\b/,
        'a policy with no declared type gets a neutral placeholder, not a guessed one' );
}

done_testing;

__END__

=head1 NAME

362-a-warning-that-only-knew-one-name.t - card-unlinked shares the done-role warning

=head1 DESCRIPTION

card-unlinked and parent-ahead-of-children both depend on
C<column_roles(type)-E<gt>{done}> to know which cards have already
shipped, and policy_unresolved's own detector only ever warned about one
of them, by rule name. This proves both are now reported unresolved when
the done role is undeclared, that declaring both together reports two
separate findings, and that the fix command in the detail names the
policy's own C<--type> rather than a hardcoded C<ticket> - a second bug
found investigating the first.

=cut
