#!/usr/bin/env perl
# A backward move-in is still a move-in.
#
# _apply_column_required_actions populates a column's required-action
# template on the way forward, and resets already-satisfied items back to
# pending on the way back through the columns crossed. What it never did was
# populate the destination column's OWN template on a backward move, if the
# card never picked it up on an earlier forward pass - which happens exactly
# when the template was declared after the card had already left that
# column once. TKT-464 (third facet, found live on TKT-458).

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-22T00:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Backward', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, a, b, done'],
    sow_prefix => 'BWS', epic_prefix => 'BWE', ticket_prefix => 'BWT',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Passed through before the template existed' );
my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );

# Forward through 'a' while it has no template, then to 'b'.
$providers{move}->( { type => 'ticket', ref => $card->{ref}, column => 'a', _signed_in => 'michael' } );
$providers{move}->( { type => 'ticket', ref => $card->{ref}, column => 'b', _signed_in => 'michael' } );

my $before = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
is( scalar @{ $before->{required_items} }, 0, q{no template existed on 'a' when the card passed through it} );

# Declared afterward - the situation TKT-458 hit in practice.
$tira->column_update( project => $root, type => 'ticket', name => 'a',
    required_action => [ 'Write the thing', 'Prove the thing' ] );

# Backward b -> a.
$providers{move}->( { type => 'ticket', ref => $card->{ref}, column => 'a', _signed_in => 'michael' } );
my $after = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
is( scalar @{ $after->{required_items} }, 2, q{the backward move-in populates 'a's template, same as a forward move-in would} );
is_deeply( [ sort map { $_->{item} } @{ $after->{required_items} } ],
    [ 'Prove the thing', 'Write the thing' ], 'both declared items are present, tagged to the right column' );
is( $after->{required_items}[0]{column}, 'a', 'and tagged to the column the card actually landed on' );

# Moving forward again must not duplicate what a second backward-then-forward
# crossing would otherwise re-add.
$providers{move}->( { type => 'ticket', ref => $card->{ref}, column => 'b', _signed_in => 'michael' } );
$providers{move}->( { type => 'ticket', ref => $card->{ref}, column => 'a', _signed_in => 'michael' } );
my $twice = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
is( scalar @{ $twice->{required_items} }, 2, 'crossing the same column again does not duplicate its template items' );

done_testing;

__END__

=head1 NAME

320-a-move-that-arrived-with-nothing.t - a backward move-in populates a
column's template exactly as a forward move-in already does

=head1 DESCRIPTION

C<_apply_column_required_actions> only ever populated a destination column's
required-action template from its forward branch. A card that first crossed
a column before that column had a template, then moved backward into it
later, got nothing - the backward branch only resets items the card already
has, never adds what it's missing. TKT-464.

=cut
