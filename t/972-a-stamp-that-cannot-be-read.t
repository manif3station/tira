#!/usr/bin/env perl
# A card whose timestamp cannot be read is silently exempt from every
# age-based rule, and nothing says so.
#
# TKT-972, EPC-007. _policy_older_than's own fallback for an unparseable
# stamp - eval { _epoch_of_datetime(...) } // return 0 - makes the card
# look never old enough to every age-based rule that asks about it, and
# says nothing. Two cards with identical, complete checklists in a watched
# column: one's checklist item has a real last_updated, the other's has
# been corrupted (valid JSON, unparseable timestamp). checklist-idle
# reports the good one and stays silent about the bad one - not because
# nothing is wrong, but because the fallback cannot tell the difference
# between "nothing is wrong" and "I could not check".
#
# THE FIX: policy_evaluate now names the bad card as card-stamp-unreadable,
# the third member of the card-damaged/card-unreadable family - assembled
# outside the rule loop, through the same ledger, so it gets a number, the
# quiet ladder, and a settlement line the moment the stamp is fixed.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Find ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

sub record_path {
    my ($root, $ref) = @_;
    my $found;
    File::Find::find( { no_chdir => 1, wanted => sub {
        # no_chdir => 1 means $_ is already $File::Find::name (the full
        # path), not the bare filename - anchoring \A here would never
        # match anything but the tempdir root itself.
        $found = $File::Find::name if m{/\Q$ref\E\.json\z};
    } }, File::Spec->catdir( $root, '.tira', 'ticket' ) );
    return $found;
}

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-09-17T10:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Stamp', dir => $root, members => ['claude'],
    columns    => ['backlog, doing, done'],
    sow_prefix => 'STS', epic_prefix => 'STE', ticket_prefix => 'STT',
);
$tira->policy_add( project => $root, rule => 'checklist-idle',
    column => 'doing', age => '1h', action => 'log-only' );
$tira->policy_add( project => $root, rule => 'column-skipped',
    enter => 'done', require => 'doing', action => 'log-only' );

sub card_with_checklist {
    my ($title) = @_;
    my $ref = $tira->create_record( project => $root, type => 'ticket',
        title => $title, description => 'x', author => 'claude' )->{ref};
    $tira->checklist_add( project => $root, ref => $ref, item => 'do the thing',
        author => 'claude' );
    $tira->record_move( project => $root, ref => $ref, column => 'doing',
        author => 'claude' );
    return $ref;
}

my $good = card_with_checklist('Good stamp');
my $bad  = card_with_checklist('Bad stamp');

# Both checklists were last touched at creation, an hour before the clock
# above - old enough for the 1h policy to fire on the good one.

# --- corrupt the bad card's checklist stamp, valid JSON, unparseable time --

my $path = record_path( $root, $bad );
die "could not find $bad on disk" if !defined $path;
open my $fh, '<:raw', $path or die "$path: $!";
my $json = do { local $/; <$fh> };
close $fh;
$json =~ s/"last_updated"\s*:\s*"[^"]*"/"last_updated":"not a timestamp"/;
open my $out, '>:raw', $path or die "$path: $!";
print {$out} $json;
close $out;

$now = '2026-09-17T12:00:00Z';    # 2h after creation - past the 1h policy age
my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
my @said = map { "$_->{rule} $_->{ref}" } @{ $pass->{violations} || [] };

# --- the good card is reported, exactly as it always was --------------------

ok( scalar( grep { /^checklist-idle \Q$good\E$/ } @said ), 'checklist-idle fires on the card with a real timestamp' )
  or diag( 'violations: ' . join( ' ;; ', @said ) );

# --- the bad card gets NO checklist-idle finding -----------------------------
#
# Not because it is fine - it has the identical complete checklist - but
# because the rule could not measure it at all. This is the control that
# proves the exemption is real, not merely asserted.

ok( !scalar( grep { /^checklist-idle \Q$bad\E$/ } @said ),
    'checklist-idle stays silent on the card whose stamp cannot be read - the '
      . 'exemption this card is about' )
  or diag( 'violations: ' . join( ' ;; ', @said ) );

# --- and THE FIX: the bad card is named by card-stamp-unreadable instead ----

ok( scalar( grep { /^card-stamp-unreadable \Q$bad\E$/ } @said ),
    'card-stamp-unreadable names the card whose age-based rule could not '
      . 'read its stamp, instead of leaving it invisible' )
  or diag( 'violations: ' . join( ' ;; ', @said ) );

ok( !scalar( grep { /^card-stamp-unreadable \Q$good\E$/ } @said ),
    'and does not fire on the good card - a genuinely readable stamp is not '
      . 'this diagnostic\'s business' );

# --- fixing the stamp settles it, the same as any other violation ----------

$json =~ s/"last_updated"\s*:\s*"not a timestamp"/"last_updated":"2026-09-17T10:00:00Z"/;
open my $fixed, '>:raw', $path or die "$path: $!";
print {$fixed} $json;
close $fixed;

my $second = $tira->police_pass( project => $root, store => $store, world => {} );
my @said2  = map { "$_->{rule} $_->{ref}" } @{ $second->{violations} || [] };

ok( !scalar( grep { /^card-stamp-unreadable \Q$bad\E$/ } @said2 ),
    'and once the stamp is fixed, card-stamp-unreadable stops naming the card '
      . '- the settlement every other diagnostic in this family gets' );

ok( scalar( grep { /^checklist-idle \Q$bad\E$/ } @said2 ),
    'and checklist-idle can now measure it too, since the stamp is real again' )
  or diag( 'violations: ' . join( ' ;; ', @said2 ) );

# --- a card whose HISTORY is unreadable does not ALSO get this diagnosis ---
#
# card-unreadable already names a card whose history could not be read at
# all; card-stamp-unreadable is a narrower, different fact about a card
# that reads fine but carries a stamp an age rule cannot parse. A card with
# BOTH faults should say so once, not twice in two different words - caught
# by Codex review, which found the first draft reported both.

{
    # column-skipped, not checklist-idle, is what reads history here - so
    # this card goes straight from backlog to 'done', skipping the required
    # 'doing', rather than through card_with_checklist's own path.
    my $third = $tira->create_record( project => $root, type => 'ticket',
        title => 'Unreadable history, bad stamp too', description => 'x',
        author => 'claude' )->{ref};
    $tira->record_move( project => $root, ref => $third, column => 'done',
        author => 'claude' );

    my $third_path = record_path( $root, $third );
    die "could not find $third on disk" if !defined $third_path;

    open my $tfh, '<:raw', $third_path or die "$third_path: $!";
    my $tjson = do { local $/; <$tfh> };
    close $tfh;
    $tjson =~ s/"last_updated"\s*:\s*"[^"]*"/"last_updated":"not a timestamp"/;
    open my $tout, '>:raw', $third_path or die "$third_path: $!";
    print {$tout} $tjson;
    close $tout;

    # A malformed byte in the card's own history file, the same fault
    # t/173 exercises for card-damaged/card-unreadable.
    my $journal = File::Spec->catfile( $root, '.tira', 'history', "$third.jsonl" );
    open my $append, '>>:raw', $journal or die "$journal: $!";
    print {$append} qq({"after":"broken \xd7 byte","at":"2026-09-17T10:00:00Z",)
      . qq("author":null,"before":null,"field":"title","op":"update","ref":"$third"}\n);
    close $append;

    my $third_pass = $tira->police_pass( project => $root, store => $store, world => {} );
    my @third_said = map { "$_->{rule} $_->{ref}" } @{ $third_pass->{violations} || [] };

    ok( scalar( grep { /^card-unreadable \Q$third\E$/ or /^card-damaged \Q$third\E$/ } @third_said ),
        'the unreadable-history fault is still reported' )
      or diag( 'violations: ' . join( ' ;; ', @third_said ) );

    ok( !scalar( grep { /^card-stamp-unreadable \Q$third\E$/ } @third_said ),
        'and card-stamp-unreadable does NOT also fire for the same card - one '
          . 'diagnosis, not two, for a card already explained' )
      or diag( 'violations: ' . join( ' ;; ', @third_said ) );
}

done_testing();

__END__

=head1 NAME

972-a-stamp-that-cannot-be-read.t - a card whose timestamp cannot be
parsed is named by card-stamp-unreadable, not silently exempted

=head1 WHY

TKT-972. C<_policy_older_than>'s fallback for an unparseable stamp - never
old enough - is correct in that it must not crash a pass, but it said
nothing about the difference between a card that is fine and a card
nobody could check. Two cards with identical checklists in a watched
column, one with a corrupted C<last_updated>: C<checklist-idle> fired on
the good one and stayed silent on the bad one, which reads as the bad
card having nothing wrong with it.

=head1 WHAT IS ASSERTED

That the good card is still reported (the control), that the bad card gets
no C<checklist-idle> finding (the exemption this card is about, proven
rather than assumed), that C<card-stamp-unreadable> names the bad card
instead (the fix) and does not fire on the good one, and that fixing the
stamp settles the diagnostic and lets the original rule measure the card
again.

=cut
