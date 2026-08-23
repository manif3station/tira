#!/usr/bin/env perl
# card-still's finding gave the elapsed time and never the limit it crossed,
# nor which of the two possible sources set that limit - a column's own
# notify_after, or the policy's own --age fallback when the column has none.
#
# Measured on a real reader: a card-still declared at --age 6h fired instead
# on a different card after only 2h, because that column's own notify_after
# (120 minutes) governed instead - and 2h elapsed against a 2h limit reads as
# though the elapsed time WAS the threshold, since nothing said otherwise.
# The two sources are fixed in different places (tira.column.update vs
# re-declaring the policy), so a reader who cannot tell them apart cannot act
# on the finding without a second command. TKT-290.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-17T09:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Limits', dir => $root, members => ['claude'],
    columns => ['backlog, implement, unit-test, done'],
    sow_prefix => 'LMS', epic_prefix => 'LME', ticket_prefix => 'LMT',
);

sub still {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return { map { $_->{ref} => $_ }
          grep { ( $_->{rule} // '' ) eq 'card-still' } @{ $pass->{violations} } };
}

# --- a column's own notify_after governs, and the finding names it ------------

$tira->policy_add( project => $root, rule => 'card-still', action => 'bridge-reminder', age => '6h' );
$tira->column_update( project => $root, type => 'ticket', name => 'unit-test', notify_after => 120 );

my $watched = $tira->create_record( project => $root, type => 'ticket', title => 'Sits in unit-test' );
$tira->record_move( author => 'claude', project => $root, ref => $watched->{ref}, column => 'unit-test' );

{
    $now = '2026-08-17T11:01:00Z';    # 2h01m later - past the column's 120m, well under the policy's 6h
    my $found = still();
    ok( $found->{ $watched->{ref} }, 'the column\'s own limit (2h) fires well before the policy\'s (6h) would' );

    my $detail = $found->{ $watched->{ref} }{detail} // '';
    like( $detail, qr/this column allows 2h/, 'the finding names the limit that was actually crossed' );
    like( $detail, qr/unit-test notify_after/, 'and which column, and which field, set it' );
    unlike( $detail, qr/no column limit set/, 'and does not say the opposite of what happened' );
}

# --- a column with no notify_after falls back to the policy's own age, named too --

my $unwatched = $tira->create_record( project => $root, type => 'ticket', title => 'Sits in implement' );
$tira->record_move( author => 'claude', project => $root, ref => $unwatched->{ref}, column => 'implement' );

{
    $now = '2026-08-17T17:02:00Z';    # past the policy's 6h fallback
    my $found = still();
    ok( $found->{ $unwatched->{ref} }, 'the policy\'s own age fires when the column sets nothing' );

    my $detail = $found->{ $unwatched->{ref} }{detail} // '';
    like( $detail, qr/the policy allows 6h/, 'the finding names the policy\'s own limit this time' );
    like( $detail, qr/no column limit set/, 'and says plainly that no column limit governed it' );
    unlike( $detail, qr/notify_after/, 'and does not claim a column field that was never set' );
}

done_testing;

__END__

=head1 NAME

331-a-limit-that-never-said-what-it-was.t - card-still names the limit it crossed and its source

=head1 DESCRIPTION

C<card-still>'s finding gave elapsed time only, never the threshold it
crossed nor which of the two possible sources - a column's own
C<notify_after>, or the policy's own C<--age> when the column sets
nothing - governed it. Both are now named in the finding, since they are
fixed in different places and a reader who cannot tell them apart cannot
act without a second command. TKT-290.

=cut
