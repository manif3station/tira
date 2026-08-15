#!/usr/bin/env perl
# A policy narrowed to one card reports one card.
#
# SKILLS.md promises it plainly: "Declaring it on a card beats declaring it on
# the column, which beats the board, which beats the project - per rule, so one
# exception cannot switch the rest off."
#
# discard-unexplained ignored that entirely. Two cards discarded, a policy
# declared with --ref for the first only, and both were reported: the scope was
# accepted, stored on the policy, and never consulted, because that branch loops
# every record and never calls the resolver every other card rule calls.
#
# It is a setting accepted, ignored and believed. Somebody narrowing a noisy
# rule to one card gets no error, sees the policy stored with the ref on it, and
# is told by the documentation that it is now narrow. Then it fires on
# everything, and the natural conclusion is that the rule is broken rather than
# that the scope was never read.
#
# Two more rules never consult it and cannot: board-still and bridge-unread are
# about the whole board, so a card scope could never narrow either - it is
# refused when it is set, which is what TKT-178 did for card-sandbox-missing.
#
# wip-limit looked like a third and is not. It counts a column, so a card scope
# reads as meaningless until you find that the cascade uses exactly that to give
# one card a different limit from the rest of its column. This file refused it,
# t/87-policy-cascade.t caught it within the same run, and the assertion had
# been written from what the rule looked like rather than from what the suite
# already proved about it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'scoped' );
$tira->project_new(
    name => 'Scoped', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SCS', epic_prefix => 'SCE', ticket_prefix => 'SCT',
);

my $watched = $tira->create_record( project => $root, type => 'ticket',
    title => 'The one the policy names' )->{ref};
my $other = $tira->create_record( project => $root, type => 'ticket',
    title => 'A different card entirely' )->{ref};
$tira->record_move( project => $root, ref => $_, column => 'discard' ) for ( $watched, $other );

sub reported {
    my ($store) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    return [ sort map { $_->{ref} }
        grep { $_->{rule} eq 'discard-unexplained' } @{ $pass->{violations} } ];
}

# --- narrowed to one card -------------------------------------------------------------

$tira->policy_add( project => $root, rule => 'discard-unexplained',
    ref => $watched, action => 'bridge-reminder' );

is_deeply( reported( File::Spec->catdir( $tmp, 'narrow' ) ), [$watched],
    'a policy declared for one card reports that card and no other' );

# --- and the board-wide form is unchanged -----------------------------------------------
#
# The other half of the promise. If narrowing worked by reporting less of
# everything this would pass while breaking every board that declares the rule
# the ordinary way.

{
    my $wide = File::Spec->catdir( $tmp, 'wide' );
    my $board = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );
    my $dir = File::Spec->catdir( $tmp, 'boardwide' );
    $board->project_new(
        name => 'Board Wide', dir => $dir, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'BWS', epic_prefix => 'BWE', ticket_prefix => 'BWT',
    );
    my @dropped = map {
        my $ref = $board->create_record( project => $dir, type => 'ticket',
            title => "dropped $_" )->{ref};
        $board->record_move( project => $dir, ref => $ref, column => 'discard' );
        $ref;
    } ( 1, 2 );
    $board->policy_add( project => $dir, rule => 'discard-unexplained',
        action => 'bridge-reminder' );

    my $pass = $board->police_pass( project => $dir, store => $wide,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is_deeply(
        [ sort map { $_->{ref} } grep { $_->{rule} eq 'discard-unexplained' }
              @{ $pass->{violations} } ],
        [ sort @dropped ],
        'a policy declared for the board still reports every discarded card' );
}

# --- a scope a rule cannot act on is refused ---------------------------------------------
#
# board-still and bridge-unread are about the whole board, so a card scope can
# never narrow either. Accepting one stores a policy nobody can make sense of -
# refused at declaration, the way card-sandbox-missing refuses a project with no
# repository.

{
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Not a board' )->{ref};

    for my $case (
        [ 'board-still',   { age => '1h' } ],
        [ 'bridge-unread', { age => '1h' } ],
    ) {
        my ( $rule, $extra ) = @{$case};
        ok( !eval {
                $tira->policy_add( project => $root, rule => $rule, ref => $card,
                    %{$extra}, action => 'bridge-reminder' );
                1;
            },
            "$rule refuses a card scope it could never act on" );
        like( $@, qr/card|scope|whole board|column/i, "and says why for $rule" );
    }
}

# --- but wip-limit keeps its card scope, which is a real feature ------------------------------
#
# It counts a column, so at first reading a card scope looks like something it
# could never use. The cascade uses exactly that: a policy on a card gives that
# card a different limit from the rest of its column, and t/87 has asserted it
# for as long as the cascade has existed.
#
# This file first refused it along with the other two, and t/87 caught it. The
# assertion was written from what the rule looked like rather than from what the
# suite already proved about it.

{
    my $limited = $tira->create_record( project => $root, type => 'ticket',
        title => 'Its own limit' )->{ref};
    ok( eval {
            $tira->policy_add( project => $root, rule => 'wip-limit', ref => $limited,
                column => 'implement', max => 1, action => 'bridge-reminder' );
            1;
        },
        'wip-limit keeps a card scope, because the cascade gives one card its own limit' )
      or diag($@);
}

# --- while those rules are still declarable without one -------------------------------------

{
    my $plain = File::Spec->catdir( $tmp, 'plain' );
    my $fine = Tira->new;
    $fine->project_new(
        name => 'Plain', dir => $plain, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'PLS', epic_prefix => 'PLE', ticket_prefix => 'PLT',
    );
    ok( eval {
            $fine->policy_add( project => $plain, rule => 'board-still', age => '1h',
                action => 'bridge-reminder' );
            1;
        },
        'and a board rule declared without a card scope is accepted exactly as before' )
      or diag($@);
}

done_testing;

__END__

=head1 NAME

185-a-scope-that-means-something.t - a policy narrowed to one card reports one card

=head1 DESCRIPTION

C<SKILLS.md> promises that declaring a policy on a card beats declaring it on
the column, which beats the board. C<discard-unexplained> ignored that: a policy
declared with C<--ref> for one card reported every discarded card, because its
branch never consulted the resolver every other card rule uses.

Two rules never consult it and cannot: C<board-still> and C<bridge-unread> are
about the whole board, so a card scope could never narrow either, and it is
refused when it is set rather than stored
and ignored.

=cut
