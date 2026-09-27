#!/usr/bin/env perl
# TKT-1162. board-still's newest-move pick, checklist-unmoved's latest-entry
# pick, and _announce_moves's/_agent_last_acted's already-notified guards all
# compared last_updated with Perl's plain string operators instead of
# converting to an absolute instant - the same DST fall-back trap TKT-1159
# fixed for created_at, but for last_updated.
#
# Card/entry A: last_updated 2026-10-25T01:59:00+0100 (00:59 UTC) - genuinely
# earlier. Card/entry B: last_updated 2026-10-25T01:01:00+0000 (01:01 UTC) -
# genuinely later. Lexically, A's string sorts AFTER B's.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Tira;
use Suite qw(engine_source);

my $A = '2026-10-25T01:59:00+0100';    # 00:59 UTC - genuinely earlier
my $B = '2026-10-25T01:01:00+0000';    # 01:01 UTC - genuinely later

ok( $A gt $B,
    q{sanity: A's raw string sorts lexically AFTER B's - the DST trap this ticket is about} );

# --- the shared helper gets the real order right ----------------------------

is( Tira::_last_updated_order( $A, $B ), -1,
    'the shared helper says the genuinely-earlier stamp sorts before the genuinely-later one' );
is( Tira::_last_updated_order( $B, $A ), 1,
    'and the reverse' );
is( Tira::_last_updated_order( '', '' ), 0,
    'two empty stamps fall back to string comparison rather than dying' );
is( Tira::_last_updated_order( 'not a date', 'also not a date' ),
    ( 'not a date' cmp 'also not a date' ),
    'two unparseable stamps fall back to the plain string comparison, unchanged from before' );

# --- board-still picks the genuinely later move, not the lexically later one --

{
    my $now   = '2026-10-25T09:00:00Z';
    my $tira  = Tira->new( clock => sub {$now} );
    my $tmp   = tempdir( CLEANUP => 1 );
    my $root  = File::Spec->catdir( $tmp, 'proj' );
    my $store = File::Spec->catdir( $tmp, 'police' );

    $tira->project_new(
        name => 'DST last_updated', dir => $root, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'DLS', epic_prefix => 'DLE', ticket_prefix => 'DLT',
    );
    $tira->policy_add( project => $root, rule => 'board-still', age => '4h',
        action => 'bridge-reminder' );

    $now = $A;
    my $earlier = $tira->create_record( project => $root, type => 'ticket',
        title => 'Touched just before the fall-back' );

    $now = $B;
    $tira->record_update( author => 'claude', project => $root, ref => $earlier->{ref},
        description => 'touched again, after the fall-back, genuinely more recently' );

    $now = '2026-10-25T04:59:00+0000';    # 3h58m after B, still within the 4h age
    my $pass = $tira->police_pass( project => $root, store => $store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is( scalar( grep { $_->{rule} eq 'board-still' } @{ $pass->{violations} } ), 0,
        'board-still reads the genuinely-later B as the last move, so the board is not yet stuck' );
}

# --- checklist-unmoved's latest-entry pick agrees --------------------------

{
    my $now   = '2026-10-25T09:00:00Z';
    my $tira  = Tira->new( clock => sub {$now} );
    my $tmp   = tempdir( CLEANUP => 1 );
    my $root  = File::Spec->catdir( $tmp, 'proj' );
    my $store = File::Spec->catdir( $tmp, 'police' );

    $tira->project_new(
        name => 'DST checklist', dir => $root, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'DCS', epic_prefix => 'DCE', ticket_prefix => 'DCT',
    );
    $tira->policy_add( project => $root, rule => 'checklist-idle',
        column => 'implement', age => '4h', action => 'bridge-reminder' );

    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Checklist touched either side of a fall-back' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'implement' );

    $now = $A;
    $tira->checklist_add( author => 'claude', project => $root, ref => $card->{ref},
        item => 'first', status => 'To Do' );

    $now = $B;
    $tira->checklist_update( author => 'claude', project => $root, ref => $card->{ref},
        id => 'CHK-001', status => 'To Do', command => ['touched'], proof => ['still not done, but touched'] );

    $now = '2026-10-25T04:59:00+0000';    # 3h58m after B, still within the 4h age
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    is( scalar( grep { $_->{rule} eq 'checklist-idle' } @{ $pass->{violations} } ), 0,
        q{checklist-idle reads the genuinely-later touch (B) as the checklist's own last activity} );
}

# --- the other two callers route through the same shared helper -----------
#
# _announce_moves's two already-notified guards and _agent_last_acted's own
# newest-first sort/skip share the identical DST trap and the identical fix -
# both already integration-tested above via board-still/checklist-idle
# exercise the same helper on the same kind of input. Asserted structurally
# here rather than with a second, heavier board+history+notification fixture
# for each: the raw `le`/`ge`/`cmp` this ticket set out to remove no longer
# appear at either site.

{
    # Asked of "the engine" rather than of lib/Tira.pm by name, the same
    # reason work_order's own sort test reads engine_source() instead of
    # opening a file - a lift that moves either function to a sibling
    # module (TKT-746's own ongoing decomposition) must not break this.
    my @lines = split /\n/, engine_source();

    my ($announce_start) = grep { $lines[$_] =~ /^sub _announce_moves/ } 0 .. $#lines;
    my ($agent_start)    = grep { $lines[$_] =~ /^sub _agent_last_acted/ } 0 .. $#lines;
    ok( defined $announce_start && defined $agent_start,
        'found both functions to inspect' );

    my $announce_body = join "\n", @lines[ $announce_start .. $announce_start + 40 ];
    my $agent_body     = join "\n", @lines[ $agent_start .. $agent_start + 25 ];

    unlike( $announce_body, qr/\$record->\{last_updated\}\s*le\s*\$already/,
        '_announce_moves no longer compares last_updated with a raw le' );
    unlike( $announce_body, qr/\$already\s*ge\s*\$move->\{at\}/,
        '_announce_moves no longer compares the notified stamp with a raw ge' );
    like( $announce_body, qr/_last_updated_order/,
        '_announce_moves routes through the shared helper instead' );

    unlike( $agent_body, qr/\$record->\{last_updated\}\s*le\s*\$newest/,
        '_agent_last_acted no longer compares last_updated with a raw le' );
    like( $agent_body, qr/_last_updated_order/,
        '_agent_last_acted routes through the shared helper instead' );
}

done_testing;

__END__

=head1 NAME

1162-a-fall-back-that-looked-later-than-it-was.t - a DST fall-back does not reverse which touch was later

=head1 DESCRIPTION

TKT-1162. board-still's newest-move pick, checklist-unmoved's/checklist-idle's
latest-entry pick, C<_announce_moves>'s two already-notified guards, and
C<_agent_last_acted>'s own newest-first sort all compared C<last_updated>
with Perl's plain string operators instead of converting to an absolute
instant - the same bug class TKT-1159 fixed for C<created_at>. All four now
route through a shared C<_last_updated_order> helper.

=cut
