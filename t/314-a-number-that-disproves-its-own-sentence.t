#!/usr/bin/env perl
# priority-skipped can be right and still say something false.
#
# _outranks_for_work settles a tie in priority by age - correctly, TKT-186
# settled that the one who has waited longer should go first. But the message
# only knew one sentence: "waits at priority N, above this card's N". When the
# tie-break is what actually fired, both cards sit at the SAME priority, and
# the sentence prints two equal numbers while claiming one is above the other.
#
# MEASURED, from this board: "being worked while TKT-282 waits at priority 5,
# above this card's 5". Five is not above five. The finding was correct - the
# reason given for it was not, and it sent the reader to fix code that was
# never broken.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );

sub reported {
    my ( $tira, $root, $store ) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    return [ grep { $_->{rule} eq 'priority-skipped' } @{ $pass->{violations} } ];
}

# --- a tie in priority is decided by age, and the message must say so ------------------

{
    my $now = '2026-08-17T01:59:55+0100';
    my $tira = Tira->new( clock => sub {$now} );
    my $root = File::Spec->catdir( $tmp, 'tie' );
    my $store = File::Spec->catdir( $tmp, 'police-tie' );

    $tira->project_new(
        name => 'Tie', dir => $root, members => [ 'michael', 'claude' ],
        columns => ['backlog, implement, done'],
        sow_prefix => 'TIS', epic_prefix => 'TIE', ticket_prefix => 'TIT',
    );
    $tira->policy_add( project => $root, rule => 'priority-skipped', action => 'bridge-reminder' );

    my $older = $tira->create_record( project => $root, type => 'ticket',
        title => 'The one that has waited since the earlier date', priority => 5 );

    $now = '2026-08-18T14:54:05+0100';
    my $newer = $tira->create_record( project => $root, type => 'ticket',
        title => 'The one worked instead, same priority', priority => 5 );
    $tira->record_move( project => $root, ref => $newer->{ref}, column => 'implement' );

    my $found = reported( $tira, $root, $store );
    is( scalar @{$found}, 1, 'the older card at the same priority is still reported' );

    my $detail = $found->[0]{detail};
    unlike( $detail, qr/waits at priority 5, above this card's 5/,
        'never prints two equal priorities while claiming one is above the other' );
    like( $detail, qr/same priority/, 'says the priority is shared, not that one outranks the other' );
    like( $detail, qr/2026-08-17/, 'and names the date that actually settles it' );
}

# --- a real priority difference keeps saying so, unchanged ------------------------------

{
    my $tira = Tira->new( clock => sub {'2026-08-20T09:00:00+0100'} );
    my $root = File::Spec->catdir( $tmp, 'differ' );
    my $store = File::Spec->catdir( $tmp, 'police-differ' );

    $tira->project_new(
        name => 'Differ', dir => $root, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'DIS', epic_prefix => 'DIE', ticket_prefix => 'DIT',
    );
    $tira->policy_add( project => $root, rule => 'priority-skipped', action => 'bridge-reminder' );

    $tira->create_record( project => $root, type => 'ticket',
        title => 'The higher-priority card, actually above', priority => 5 );
    my $working = $tira->create_record( project => $root, type => 'ticket',
        title => 'Worked at a lower priority', priority => 2 );
    $tira->record_move( project => $root, ref => $working->{ref}, column => 'implement' );

    my $found = reported( $tira, $root, $store );
    is( scalar @{$found}, 1, 'a genuine priority difference is still reported' );
    like( $found->[0]{detail}, qr/waits at priority 5, above this card's 2/,
        'and the existing priority-decided wording is unchanged' );
    unlike( $found->[0]{detail}, qr/same priority/,
        'because this one was never a tie, so it never claims to be one' );
}

done_testing;

__END__

=head1 NAME

314-a-number-that-disproves-its-own-sentence.t - priority-skipped names the fact that actually decided it

=head1 DESCRIPTION

C<_outranks_for_work> settles a priority tie by age, correctly. Before
TKT-391, the C<priority-skipped> message only had one sentence available -
"waits at priority N, above this card's N" - so an age-decided tie printed
two equal numbers while claiming one outranked the other, sending the reader
to "fix" code that was never broken. This asserts the message now names
whichever fact actually decided it: a real priority gap keeps the original
wording, and a tie names the date that settled it instead.

=cut
