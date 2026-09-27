#!/usr/bin/env perl
# priority-skipped's age tie-break, and work_order's own sort, compare two
# cards' created_at as raw local-offset strings - so a card created just
# before a DST fall-back (clocks going back an hour) and one created a few
# minutes later, after the fall-back, get created_at strings whose local
# wall-clock time goes BACKWARD even though real/UTC time moved forward.
# Lexical string comparison over that pair gives the wrong answer.
#
# Card A: created 2026-10-25T01:59:00+0100 (00:59 UTC) - genuinely older.
# Card B: created 2026-10-25T01:01:00+0000 (01:01 UTC) - genuinely newer.
# Lexically, "01:59:00+0100" sorts AFTER "01:01:00+0000" (the digit '5' in
# "59" beats the digit '0' in "01"), so a raw string comparison reads A as
# the newer of the two - exactly backward from the real UTC order.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Tira;
use Suite qw(engine_source);

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-10-25T09:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'DST', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'DFS', epic_prefix => 'DFE', ticket_prefix => 'DFT',
);
$tira->policy_add( project => $root, rule => 'priority-skipped',
    action => 'bridge-reminder' );

$now = '2026-10-25T01:59:00+0100';    # 00:59 UTC - genuinely older
my $older = $tira->create_record( project => $root, type => 'ticket',
    title => 'Created just before the fall-back, at priority 3', priority => 3 );

$now = '2026-10-25T01:01:00+0000';    # 01:01 UTC - genuinely newer
my $newer = $tira->create_record( project => $root, type => 'ticket',
    title => 'Created a few minutes later, after the fall-back', priority => 3 );

# --- the raw strings sort backward from real UTC time ----------------------

ok( $older->{created_at} gt $newer->{created_at},
    q{the genuinely-older card's created_at string sorts lexically AFTER the newer one's - the DST trap this ticket is about} );

# --- _outranks_for_work must still say the genuinely older one goes first --

sub skipped {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'priority-skipped' } @{ $pass->{violations} } ];
}

is_deeply( [ $tira->_outranks_for_work( $older, $newer ) ], [ 1, 'age' ],
    'the genuinely older card outranks the genuinely newer one for work, even though its created_at string sorts later' );

is_deeply( [ $tira->_outranks_for_work( $newer, $older ) ], [ 0, undef ],
    'and the genuinely newer card does not outrank the genuinely older one' );

# --- work_order's own sort must agree ---------------------------------------

is( $tira->work_order( project => $root )->[0]{ref}, $older->{ref},
    'work_order offers the genuinely older card first, real UTC time rather than the local-offset string' );

# --- and the rule reports taking the genuinely newer one out of turn -------

$now = '2026-10-25T09:05:00Z';
$tira->record_move( author => 'claude', project => $root, ref => $newer->{ref}, column => 'implement' );

my $found = skipped();
ok( scalar @{$found},
    'taking the genuinely newer card ahead of the genuinely older one is reported' );

# --- _outranks_for_work routes through the same shared helper work_order's --
# sort uses, rather than keeping its own duplicate epoch-comparison inline -
# the established convention TKT-1162 later applied to every last_updated
# site. Asked of "the engine" rather than of lib/Tira.pm by name, same reason
# t/1162's own structural check does (a lift must not break this).

{
    my @lines = split /\n/, engine_source();
    my ($start) = grep { $lines[$_] =~ /^sub _outranks_for_work/ } 0 .. $#lines;
    ok( defined $start, 'found _outranks_for_work to inspect' );
    my $body = join "\n", @lines[ $start .. $start + 30 ];

    unlike( $body, qr/\b(?:lt|gt|le|ge)\s*\$(?:their_age|our_age)/,
        '_outranks_for_work no longer compares created_at with a raw string operator' );
    like( $body, qr/_created_at_order/,
        '_outranks_for_work routes through the shared helper instead' );
}

done_testing;

__END__

=head1 NAME

1159-a-fall-back-that-looked-like-it-went-first.t - a DST fall-back does not reverse who waited longer

=head1 DESCRIPTION

TKT-1159. C<_outranks_for_work>'s age tie-break and C<work_order>'s own sort
compared C<created_at> with Perl's plain string operators instead of
converting to an absolute instant. C<created_at> is written in the machine's
LOCAL time with a dynamically-computed UTC offset, so a card created just
before a DST fall-back and one created a few minutes after it get
C<created_at> strings whose local wall-clock time goes backward even though
real/UTC time moved forward - and a lexical comparison over that pair gives
the wrong answer.

=cut
