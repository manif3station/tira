#!/usr/bin/env perl
# TKT-491. Found during a documentation-gap hunt while checking for other
# instances of the exact pattern TKT-280/488/490 already fixed - grepped
# every remaining 'not found' die site in lib/Tira.pm and comment_update/
# comment_remove are the only two record-entry lookups left with the
# identical gap. Both sites already have the full comments array loaded in
# the same call, so listing the real ids or naming the CMT-NNN shape costs
# nothing extra.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Comment', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'CMS', epic_prefix => 'CME', ticket_prefix => 'CMT',
);

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card with real comments', priority => 3 );
$tira->comment_add( author => 'claude', project => $root, type => 'ticket',
    ref => $card->{ref}, text => 'First' );
$tira->comment_add( author => 'claude', project => $root, type => 'ticket',
    ref => $card->{ref}, text => 'Second' );

# --- comment_update, an unknown id against a card with real comments -------

my $update_error = eval {
    $tira->comment_update( author => 'claude', project => $root, type => 'ticket',
        ref => $card->{ref}, comment => '1', text => 'Edited' );
    '';
} // $@;
like( $update_error, qr/Comment '1' not found/, 'comment_update still refuses the unknown id' );
like( $update_error, qr/addressed by id/, 'and says entries are addressed by id, not position' );
like( $update_error, qr/CMT-001/, 'and lists the ids this card actually has' );
like( $update_error, qr/CMT-002/, 'both of them, not just the first' );

# --- comment_remove, the same shape -----------------------------------------

my $remove_error = eval {
    $tira->comment_remove( author => 'claude', project => $root, type => 'ticket',
        ref => $card->{ref}, comment => '1' );
    '';
} // $@;
like( $remove_error, qr/Comment '1' not found/, 'comment_remove still refuses the unknown id' );
like( $remove_error, qr/addressed by id/, 'and says entries are addressed by id, not position' );
like( $remove_error, qr/CMT-001/, 'and lists the ids this card actually has' );
like( $remove_error, qr/CMT-002/, 'both of them, not just the first' );

# --- a genuinely empty card, both commands ----------------------------------

my $empty = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card with no comments yet', priority => 3 );

my $update_empty = eval {
    $tira->comment_update( author => 'claude', project => $root, type => 'ticket',
        ref => $empty->{ref}, comment => 'CMT-001', text => 'x' );
    '';
} // $@;
like( $update_empty, qr/Comment 'CMT-001' not found/, 'comment_update still refuses on an empty card' );
like( $update_empty, qr/CMT-001, \.\.\./, 'and names the shape the ids take, since there is nothing to list' );

my $remove_empty = eval {
    $tira->comment_remove( author => 'claude', project => $root, type => 'ticket',
        ref => $empty->{ref}, comment => 'CMT-001' );
    '';
} // $@;
like( $remove_empty, qr/Comment 'CMT-001' not found/, 'comment_remove still refuses on an empty card' );
like( $remove_empty, qr/CMT-001, \.\.\./, 'and names the shape the ids take, since there is nothing to list' );

done_testing;

__END__

=head1 NAME

376-a-comment-that-looked-like-an-id.t - comment.update/comment.remove name the id shape they want

=head1 DESCRIPTION

C<comment_update> and C<comment_remove> refused an unknown comment id with
only "Comment '<id>' not found" - true, and silent about the fact that ids
are C<CMT-NNN> rather than a position, the same gap TKT-280/488/490 already
fixed for checklist entries, required-action items, and gate/evidence
entries. The refusal now lists the card's real ids when it has any, or
names the C<CMT-NNN> shape when it has none, for both commands.

=cut
