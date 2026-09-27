#!/usr/bin/env perl
# TKT-1165. Two more DST fall-back string-comparison sites, found by Codex
# during TKT-1162's own review - distinct from TKT-1159's created_at fix and
# TKT-1162's five last_updated sites.
#
# Site 1: _priority_skipped_exempt's parent-open-only-because-child-open
# exemption compares last_updated//created_at with raw gt/le when deciding
# whether a parent is exempt because it is only waiting on an open child.
#
# Site 2: conversation-not-folded's newest-comment pick sorts comment
# created_at//at with sort{$b cmp $a} and compares with raw ge.
#
# Card/comment A: 2026-10-25T01:59:00+0100 (00:59 UTC) - genuinely earlier.
# Card/comment B: 2026-10-25T01:01:00+0000 (01:01 UTC) - genuinely later.
# Lexically, A's string sorts AFTER B's.
#
# WRITTEN RED.

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

# --- Site 1: priority-skipped's parent-open exemption ----------------------
#
# A parent ticket is exempt (priority-skipped does not fire on it) only when
# unassigned, with an open child, and the parent's own last activity is no
# later than the child's. Built so the child's last_updated is genuinely
# LATER (B) than the parent's (A), but B's string sorts lexically SMALLER -
# the exemption must still hold on real time, not string comparison.

{
    my $now  = '2026-10-25T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'proj' );

    $tira->project_new(
        name => 'DST parent-exempt', dir => $root, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'DPS', epic_prefix => 'DPE', ticket_prefix => 'DPT',
    );

    $now = $A;
    my $parent = $tira->create_record( project => $root, type => 'epic',
        title => 'Parent touched just before the fall-back' );

    $now = $B;
    my $child = $tira->create_record( project => $root, type => 'ticket',
        title => 'Open child touched after the fall-back', parent => $parent->{ref} );

    $now = '2026-10-25T09:05:00Z';
    my $records = [ $parent, $child ];
    my $exempt = $tira->_priority_skipped_exempt( $root, $parent, $records );
    is( $exempt, 1,
        'parent is exempt: the child was genuinely touched more recently than the parent, '
          . 'even though the child stamp sorts lexically smaller' );
}

# --- Site 2: conversation-not-folded's newest-comment pick -----------------

{
    my $now  = '2026-10-25T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    my $store = File::Spec->catdir( $tmp, 'police' );

    $tira->project_new(
        name => 'DST conversation', dir => $root, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'DCS', epic_prefix => 'DCE', ticket_prefix => 'DCT',
    );
    $tira->policy_add( project => $root, rule => 'conversation-not-folded',
        action => 'bridge-reminder' );

    $now = '2026-10-24T20:00:00Z';
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Conversation touched either side of a fall-back' );
    $tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'implement' );

    # The card's last WRITTEN (non-comment) change lands at $A - genuinely
    # EARLIER than the comment added at $B, but A's string sorts lexically
    # LARGER than B's. _last_card_change's own comparison ("$written ge
    # $said") must read the real order (written is earlier, so the comment
    # outran the card and the rule should fire) rather than the lexical one
    # (A's string >= B's string, which would wrongly conclude the card is
    # already up to date).
    $now = $A;
    $tira->record_update( author => 'claude', project => $root, ref => $card->{ref},
        description => 'touched just before the fall-back' );

    $now = $B;
    $tira->comment_add( author => 'claude', project => $root, ref => $card->{ref},
        text => 'comment genuinely later, after the fall-back' );

    $now = '2026-10-25T09:10:00+0000';
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    is( scalar( grep { $_->{rule} eq 'conversation-not-folded' } @{ $pass->{violations} } ), 1,
        'conversation-not-folded fires: the genuinely-newest comment (B) is later than the card, '
          . 'even though B\'s stamp sorts lexically smaller than A' );
}

# --- both sites route through the shared helper, asked of "the engine" ----

{
    my @lines = split /\n/, engine_source();

    my ($exempt_start) = grep { $lines[$_] =~ /^sub _priority_skipped_exempt/ } 0 .. $#lines;
    ok( defined $exempt_start, 'found _priority_skipped_exempt to inspect' );
    my $exempt_body = join "\n", @lines[ $exempt_start .. $exempt_start + 65 ];

    unlike( $exempt_body, qr/\$when\s+gt\s+\$latest_child/,
        '_priority_skipped_exempt no longer compares with a raw gt' );
    unlike( $exempt_body, qr/\$parent_touched\s+le\s+\$latest_child/,
        '_priority_skipped_exempt no longer compares with a raw le' );
    like( $exempt_body, qr/_last_updated_order|_created_at_order/,
        '_priority_skipped_exempt routes through a shared helper instead' );
}

done_testing;

__END__

=head1 NAME

1168-a-fall-back-that-orphaned-two-more-rules.t - two more DST fall-back sites, missed by TKT-1159/1162

=head1 DESCRIPTION

TKT-1165. Found by Codex during TKT-1162's own review. C<_priority_skipped_exempt>'s
parent-open-only-because-child-open exemption and C<conversation-not-folded>'s
newest-comment pick both compared timestamps with Perl's plain string
operators instead of converting to an absolute instant - the same bug class
TKT-1159 fixed for C<created_at> and TKT-1162 fixed for C<last_updated>, but
at two sites neither of those tickets touched.

=cut
