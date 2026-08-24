#!/usr/bin/env perl
# TKT-499. With two card-sandbox-missing policies declared for two acceptable
# sandboxes, one card produced TWO findings whose detail text was character-
# for-character identical. The branch-missing half of the message never
# depends on the policy at all; the worktree-missing half falls back to the
# generic "sandbox worktree" whenever the card records no sandbox AND that
# policy's own expected path is not among the machine's worktrees - which
# two policies naming two DIFFERENT acceptable sandboxes both satisfy
# identically when the card records none.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T16:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Duplicated', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'DUS', epic_prefix => 'DUE', ticket_prefix => 'DUT',
);
mkdir File::Spec->catdir( $root, '.git' );
my $store = File::Spec->catdir( $tmp, 'police-store' );

$tira->policy_add( project => $root, rule => 'card-sandbox-missing',
    enter => 'implement', sandbox => '/work/repo-a', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'card-sandbox-missing',
    enter => 'implement', sandbox => '/work/repo-b', action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'No sandbox recorded' );
$tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'implement' );

my $world = { branches => [], worktrees => [], processes => [], containers => [] };
my $pass = $tira->police_pass( project => $root, store => $store, world => $world );
my @found = grep { $_->{rule} eq 'card-sandbox-missing' && $_->{ref} eq $card->{ref} } @{ $pass->{violations} };

is( scalar @found, 1,
    'two policies producing identical detail text for one card report exactly once, not twice' );

# --- genuinely different findings from the two policies still both report --
# The machine has a work tree at exactly the first policy's expected path and
# not the second's, so the two policies describe two different problems
# ("not recorded on the card" vs "sandbox worktree") - not a duplicate to
# collapse.
my $other = $tira->create_record( project => $root, type => 'ticket', title => 'Elsewhere entirely' );
$tira->record_move( author => 'claude', project => $root, ref => $other->{ref}, column => 'implement' );

my $world2 = {
    branches => [ $other->{ref} ],   # branch half now satisfied for $other
    worktrees => [ '/work/repo-a/' . $other->{ref} ],   # only the FIRST policy's expected path exists
    processes => [], containers => [],
};
my $pass2 = $tira->police_pass( project => $root, store => $store, world => $world2 );
my @other_found = grep { $_->{rule} eq 'card-sandbox-missing' && $_->{ref} eq $other->{ref} } @{ $pass2->{violations} };
is( scalar @other_found, 2,
    'two policies describing genuinely different problems both still report - this is not a duplicate' );
my @details = sort map { $_->{detail} } @other_found;
like( $details[0], qr/repo-a/, 'one names the path recorded but not among what the machine found' );
like( $details[1], qr/sandbox worktree/, 'the other reports the plain absence for its own unmatched path' );

done_testing;

__END__

=head1 NAME

386-a-sentence-that-said-itself-twice.t - two policies of one rule report once, not twice, for the same fact

=head1 DESCRIPTION

TKT-499: card-sandbox-missing's message construction let two distinct
policies (declaring two different acceptable sandboxes) produce
character-for-character identical detail text when a card records no
sandbox at all - both fall back to the same generic "sandbox worktree"
wording. The environment-rule report closure now dedupes on (rule, ref,
detail) within one pass, so an identical finding for the same underlying
fact is reported once regardless of how many policies produced it, while
genuinely distinct findings (a different missing sandbox path) still both
report.
