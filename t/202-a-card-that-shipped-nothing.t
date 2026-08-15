#!/usr/bin/env perl
# A card that shipped no release can say so.
#
# His decision, answering Q-038 on 2026-08-15: a reserved value on fix_version -
# 'none' - meaning nothing was released for this card.
#
# The problem, as two live cards on this board rather than a hypothetical.
# TKT-006 'Documentation' and TKT-071 'Questions on the chain of command' are
# both in done with every checklist item ticked and no fix_version, and both had
# been at CRITICAL, seen seventeen times. Neither appears in any commit or in
# Changes, because neither shipped a release: TKT-071's whole deliverable was
# asking seven questions and getting them answered, and all seven were.
#
# So card-metrics --require fix_version would report them for ever. Putting a
# version on either would write a number on the card that is not true, which is
# worse than the open violation - and it is the unfixable-violation fault
# mt5-ai reported on TKT-200, happening to us.
#
# Reading the rule before building shrank this to almost nothing: card-metrics
# tests emptiness only, so 'none' already satisfies it and the engine needs no
# change at all. What is left is the part that carries his condition - the word
# has to be recognised rather than merely tolerated, or it becomes a way of
# switching the rule off one card at a time with nobody able to see it.
#
# That is what this file pins: the word works, the absence still fires, and the
# cards claiming it can be counted.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'board' );

$tira->project_new(
    name => 'Shipped Nothing', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'SNS', epic_prefix => 'SNE', ticket_prefix => 'SNT',
);
$tira->policy_add( project => $root, rule => 'card-metrics',
    enter => 'done', require => 'fix_version', action => 'bridge-reminder' );

sub reported {
    my ($store) = @_;
    my $pass = $tira->police_pass( project => $root,
        store => File::Spec->catdir( $tmp, $store ),
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    return [ map { $_->{ref} } grep { $_->{rule} eq 'card-metrics' } @{ $pass->{violations} } ];
}

my $shipped = $tira->create_record( project => $root, type => 'ticket',
    title => 'Shipped in a release' )->{ref};
my $nothing = $tira->create_record( project => $root, type => 'ticket',
    title => 'Asked seven questions and got seven answers' )->{ref};
my $silent = $tira->create_record( project => $root, type => 'ticket',
    title => 'Says nothing at all' )->{ref};
$tira->record_move( project => $root, ref => $_, column => 'done' )
  for ( $shipped, $nothing, $silent );

# --- before anybody answers, all three are reported ------------------------------------

is( scalar @{ reported('bare') }, 3, 'a card in done with no version is reported' );

# --- a real version answers it, as it always did ------------------------------------------

$tira->record_update( project => $root, ref => $shipped, fix_version => '1.98' );

# --- and so does the word for having shipped nothing ----------------------------------------
#
# His condition, and the whole of this card: the word has to be an answer.

$tira->record_update( project => $root, ref => $nothing, fix_version => 'none' );

is_deeply( reported('answered'), [$silent],
    'only the card that has said nothing is still reported' );

# --- while the word stays visible, so it cannot quietly switch the rule off -------------------
#
# A reader has to be able to ask which cards shipped nothing. Without that,
# 'none' is a way of turning the rule off one card at a time and nobody can see
# it happening - which is a worse state than the violation it settles.

{
    my $claiming = $tira->record_list( project => $root, type => 'ticket',
        fields => [ 'ref', 'fix_version' ] );
    my @none = sort map { $_->{ref} }
      grep { ( $_->{fix_version} // '' ) eq 'none' } @{$claiming};
    is_deeply( \@none, [$nothing], 'the cards claiming to have shipped nothing can be listed' );

    my @released = sort map { $_->{ref} }
      grep { ( $_->{fix_version} // '' ) =~ /\A\d/ } @{$claiming};
    is_deeply( \@released, [$shipped],
        'and are not mistaken for the ones that shipped a release' );
}

# --- and a card that shipped nothing is still a card that shipped nothing ---------------------
#
# The word is recorded as given. Nothing normalises it away, because a reader
# comparing two boards has to see the same word on both.

is( $tira->record_show( project => $root, type => 'ticket', ref => $nothing )->{fix_version},
    'none', 'the word is stored exactly as it was given' );

done_testing;

__END__

=head1 NAME

202-a-card-that-shipped-nothing.t - 'none' is an answer, not a silence

=head1 DESCRIPTION

Two cards on this board reached done having shipped no release, and
C<card-metrics --require fix_version> would have reported them for ever: a
version would have been untrue, and the violation was unclosable.

C<none> is the reserved word for it. The rule needed no change - it tests
emptiness - so what is asserted here is that the word answers the rule, that a
card saying nothing at all is still reported, and that cards claiming C<none>
can be listed separately from those that shipped a release, so the word cannot
quietly become a way of switching the rule off.

=cut
