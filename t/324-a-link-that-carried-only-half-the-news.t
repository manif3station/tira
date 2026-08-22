#!/usr/bin/env perl
# Giving an orphaned card a home is one conceptual moment, not two commands.
#
# hierarchy.link only ever set parent/child. Every card that reaches the
# board without a parent needs the same follow-up the moment it is triaged:
# link it AND usually give it a priority and an assignee in the same breath -
# an untriaged card is not yet real work. This session alone ran that
# two-step dance four times in an hour. --parent stays refused on
# ticket.update (TKT-362: a refusal beats a silent no-op), so this is the
# other direction - hierarchy.link, whose whole job is already touching the
# child record, optionally sets two more fields on that same write.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-22T00:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Homeless', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, done'],
    sow_prefix => 'HMS', epic_prefix => 'HME', ticket_prefix => 'HMT',
);

my $epic = $tira->create_record( project => $root, type => 'epic', title => 'A home for orphans' );

# --- neither flag: unchanged from before this ticket ------------------------------

{
    my $orphan = $tira->create_record( project => $root, type => 'ticket', title => 'Just a link, nothing implied' );
    my $result = $tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $orphan->{ref} );
    is( $result->{parent}, $epic->{ref}, 'a plain link still returns parent/child' );
    my $linked = $tira->record_show( project => $root, type => 'ticket', ref => $orphan->{ref} );
    is( $linked->{linkage}{epic_ref}, $epic->{ref}, 'and the parent is set' );
    is( $linked->{priority}, undef, 'no priority is implied' );
    is( $linked->{assignee}, undef, 'no assignee is implied' );
}

# --- --priority sets both parent and priority in one call -------------------------

{
    my $orphan = $tira->create_record( project => $root, type => 'ticket', title => 'Give it urgency too' );
    $tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $orphan->{ref}, priority => 5 );
    my $linked = $tira->record_show( project => $root, type => 'ticket', ref => $orphan->{ref} );
    is( $linked->{linkage}{epic_ref}, $epic->{ref}, 'parent is set' );
    is( $linked->{priority}, 5, 'and priority landed in the same call' );
}

# --- --assignee sets both parent and assignee in one call -------------------------

{
    my $orphan = $tira->create_record( project => $root, type => 'ticket', title => 'Give it an owner too' );
    $tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $orphan->{ref}, assignee => 'claude' );
    my $linked = $tira->record_show( project => $root, type => 'ticket', ref => $orphan->{ref} );
    is( $linked->{linkage}{epic_ref}, $epic->{ref}, 'parent is set' );
    is( $linked->{assignee}, 'claude', 'and assignee landed in the same call' );
}

# --- both together --------------------------------------------------------------

{
    my $orphan = $tira->create_record( project => $root, type => 'ticket', title => 'Everything at once' );
    $tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $orphan->{ref},
        priority => 3, assignee => 'michael' );
    my $linked = $tira->record_show( project => $root, type => 'ticket', ref => $orphan->{ref} );
    is( $linked->{linkage}{epic_ref}, $epic->{ref}, 'parent is set' );
    is( $linked->{priority}, 3, 'priority landed' );
    is( $linked->{assignee}, 'michael', 'and assignee landed, both in one write' );
}

# --- an invalid value refuses the whole call, link included -----------------------

{
    my $orphan = $tira->create_record( project => $root, type => 'ticket', title => 'A bad priority must not link either' );
    my $error = eval {
        $tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $orphan->{ref}, priority => 9 );
        1;
    } ? '' : $@;
    like( $error, qr/Priority must be/, 'an invalid priority refuses' );
    my $unlinked = $tira->record_show( project => $root, type => 'ticket', ref => $orphan->{ref} );
    is( $unlinked->{linkage}{epic_ref}, undef, 'and the link itself did not happen either - not a partial write' );
}

{
    my $orphan = $tira->create_record( project => $root, type => 'ticket', title => 'An unknown assignee must not link either' );
    my $error = eval {
        $tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $orphan->{ref}, assignee => 'nobody-here' );
        1;
    } ? '' : $@;
    like( $error, qr/Unknown project person/, 'an unknown assignee refuses' );
    my $unlinked = $tira->record_show( project => $root, type => 'ticket', ref => $orphan->{ref} );
    is( $unlinked->{linkage}{epic_ref}, undef, 'and the link itself did not happen either' );
}

done_testing;

__END__

=head1 NAME

324-a-link-that-carried-only-half-the-news.t - hierarchy.link optionally sets priority and assignee in the same write

=head1 DESCRIPTION

Every card that reaches the board without a parent needs a home
(hierarchy.link) and, in the same breath, usually a priority and an
assignee - an untriaged card is not yet real work. Before this,
hierarchy.link only ever set parent/child, so giving a card a home cost two
round trips every time. hierarchy.link now accepts optional C<priority> and
C<assignee>, applied to the child in the same write as the link - omitting
both leaves it exactly as before. An invalid value for either refuses the
whole call, the link included, rather than linking and silently dropping a
bad value.

=cut
