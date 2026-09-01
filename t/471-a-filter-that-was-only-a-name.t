#!/usr/bin/env perl
# TKT-802. tasklist_list only ever read all_sessions/status/unlinked/sort
# out of its arguments - --ref was accepted by the generic CLI parser
# (since --ref is a normal option name on many other commands) and then
# silently dropped, with no filtering and no error. A caller asking "what
# does this one card have on the shared tasklist" got back the WHOLE list
# instead, wrongly, and without being told anything was wrong.
#
# Confirmed live and independently reported twice: found this session
# while working TKT-675 (needed one card's own item among ~140 and had to
# scan by eye), and reported separately by the owner as TKT-803 (merged
# here) - he had closed a required action on DD-665 citing tasklist.list
# --ref DD-665 as proof, which was right only by coincidence (one card had
# tasks at the time) and would have silently answered wrong the moment a
# second card did.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-01T10:00:00+0100' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Filtered', dir => $root, members => ['ada'],
    columns => ['backlog, doing, done'],
    sow_prefix => 'FLS', epic_prefix => 'FLE', ticket_prefix => 'FLT',
);

my $card_a = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'Card A' );
my $card_b = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'Card B' );

$tira->tasklist_add( project => $root, text => 'Item for A', refs => [ $card_a->{ref} ] );
$tira->tasklist_add( project => $root, text => 'Item for B', refs => [ $card_b->{ref} ] );
$tira->tasklist_add( project => $root, text => 'Item for nobody' );

my $for_a = $tira->tasklist_list( project => $root, ref => $card_a->{ref} );
is( scalar @{$for_a}, 1, '--ref filters to only the one item linked to that card - the fix' );
is( $for_a->[0]{text}, 'Item for A', 'the right one' );

my $for_b = $tira->tasklist_list( project => $root, ref => $card_b->{ref} );
is( scalar @{$for_b}, 1, 'and a different card gets a different, equally narrow answer' );
is( $for_b->[0]{text}, 'Item for B', 'the right one' );

my $for_nobody = $tira->tasklist_list( project => $root, ref => 'FLT-999' );
is_deeply( $for_nobody, [], 'a ref matching nothing returns empty, not the whole list - the exact silent-drop this replaces' );

# --- composes with the existing filters, not just standing alone -----------

$tira->tasklist_update( project => $root, id => $for_a->[0]{id}, status => 'done' );
my $composed = $tira->tasklist_list( project => $root, ref => $card_a->{ref}, status => 'pending' );
is_deeply( $composed, [], '--ref composes with --status - a done item is excluded even though it matches the ref' );

my $unlinked_and_ref = $tira->tasklist_list( project => $root, ref => $card_a->{ref}, unlinked => 1 );
is_deeply( $unlinked_and_ref, [], '--ref composes with --unlinked too - an item WITH refs never matches an unlinked-only ask' );

done_testing;

__END__

=head1 NAME

t/471-a-filter-that-was-only-a-name.t - tasklist.list's --ref actually
filters instead of being silently accepted and ignored

=head1 DESCRIPTION

C<tasklist_list> read C<all_sessions>, C<status>, C<unlinked>, and
C<sort> out of its arguments - never C<ref>. Because C<--ref> is a
normal option name on many other Tira commands, the generic CLI parser
accepted it without complaint and the filter it implied never happened:
C<tasklist.list --ref CARD> returned the entire shared list, silently
wrong rather than refused.

Fixed by filtering on C<ref>, matching against each item's C<refs>
array, composing with the existing filters the same way they already
compose with each other. TKT-802 (merged with the owner's independent
report, TKT-803).

=cut
