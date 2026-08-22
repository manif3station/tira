#!/usr/bin/env perl
# Asking which card to work next does not cost a fifth of a megabyte.
#
# Measured on two boards independently, by two projects that had not seen each
# other's report: 94KB on mt5-ai's, and 223,584 bytes on Zenandi's. The command
# names one card and returns it, and everything it was chosen over, in full -
# every acceptance criterion, every key detail, the whole description. Zenandi's
# board has one SOW carrying 80 key_details and 46 questions, so the answer to
# "which ref" arrived with all of it attached.
#
# Both of them checked before reporting rather than assuming. --brief, --field
# ref and --fields ref were all refused here, and Zenandi is explicit that the
# --field refusal is 2.42's mechanism working exactly as designed and should not
# be relaxed - a flag accepted and dropped is worse than one refused. What was
# missing was the projection itself, which show and list have had all along.
#
# The changelog's own argument for this command was the 1,947,507 bytes a
# hand-rolled caller spent reading the whole board. 223KB is a large improvement
# on that and the same mistake in miniature.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-17T19:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Sized', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SZS', epic_prefix => 'SZE', ticket_prefix => 'SZT',
);

# Cards with the bulk the reporting boards carry, so the measurement below is
# about the shape of the answer rather than about three thin fixtures.
for my $i ( 1 .. 3 ) {
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => "Waiting, and carrying its whole history $i", priority => $i );
    $tira->record_update( author => 'claude', project => $root, ref => $card->{ref},
        key_details => [ map { "A detail long enough to matter, number $_" } 1 .. 40 ],
        acceptance_criteria => [ map { "An acceptance criterion, number $_" } 1 .. 20 ],
        description => 'A description of the kind a real card carries. ' x 40 );
}

# --- the answer as it was ---------------------------------------------------------

my $whole = $tira->work_order( project => $root );
is( scalar @{$whole}, 3, 'three cards are waiting' );
ok( exists $whole->[0]{key_details},
    'and asked for plainly, the answer carries everything each card has' );

# --- and the answer asked for by field ---------------------------------------------

{
    my $narrow = $tira->work_order( project => $root, fields => [qw(ref title priority)] );

    is( scalar @{$narrow}, 3, 'asking for three fields still answers about every card' );
    is_deeply( [ sort keys %{ $narrow->[0] } ], [qw(priority ref title)],
        'and each card carries those three fields and nothing else' );

    is( $narrow->[0]{ref}, $whole->[0]{ref},
        'the card named is the same card, so the projection did not change the answer' );
    is_deeply( [ map { $_->{ref} } @{$narrow} ], [ map { $_->{ref} } @{$whole} ],
        'and the order is the same, which is the part a projection could quietly break' );
}

# --- measured, because that is what was reported -------------------------------------
#
# A ratio rather than a byte count: the fixture is not their board, and the
# claim is about the shape of the answer rather than about a number that would
# rot the moment a card grew.

{
    my $before = length Tira::json_object()->canonical->encode($whole);
    my $after  = length Tira::json_object()->canonical->encode(
        $tira->work_order( project => $root, fields => [qw(ref title priority)] ) );

    cmp_ok( $after * 10, '<', $before,
        'asking for the three fields that answer the question costs under a tenth' );
    note("full answer $before bytes, projected answer $after bytes");
}

# --- and the sort is not done on fields the caller removed ---------------------------
#
# The trap in this change, and the reason the projection happens last: the order
# is decided by priority, created_at and ref, and a caller asking only for ref
# would otherwise be ordering by fields that were no longer there.

{
    my $only_ref = $tira->work_order( project => $root, fields => ['ref'] );
    is_deeply( [ map { $_->{ref} } @{$only_ref} ], [ map { $_->{ref} } @{$whole} ],
        'asking for the reference alone still answers in the enforced order' );
}

# --- proved by projecting before sorting ----------------------------------------------

{
    my @projected = map { { ref => $_->{ref} } } @{$whole};
    my @resorted  = sort {
        ( $b->{priority} // 0 ) <=> ( $a->{priority} // 0 )
          || ( $a->{created_at} // '' ) cmp( $b->{created_at} // '' )
          || ( $a->{ref} // '' ) cmp( $b->{ref} // '' )
    } @projected;

    isnt( join( ',', map { $_->{ref} } @resorted ),
        join( ',', map { $_->{ref} } @{$whole} ),
        'sorting after the projection loses the order, which is why it is done first' );
}

done_testing;

__END__

=head1 NAME

261-an-answer-sized-like-an-answer.t - the projection tira.next was missing

=head1 DESCRIPTION

C<tira.next> answered "which card to work" with every field of every card it
considered - 94KB on one reporting board, 223,584 bytes on another. It takes the
same C<--fields>, C<--brief> and C<--truncate> projection C<show> and C<list>
have always had.

The projection runs after the sort, because the order is decided by C<priority>,
C<created_at> and C<ref>, and a caller asking only for C<ref> would otherwise be
ordering by fields it had just removed.

=cut
