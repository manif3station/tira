#!/usr/bin/env perl
# TKT-638. discard-unexplained's test is:
#
#   next if @{ $record->{comments} // [] };
#
# It counts comments, it does not read them, and it does not ask when they
# were written. So the rule fires only on a card that has never had a
# single comment in its life - a card discarded after any earlier
# conversation, about anything unrelated to the discard, is silently
# exempt even though nothing on it actually explains why it was set aside.
#
# Reproduced against the pre-fix source: a card with an old, unrelated
# comment (written before the discard) is treated as explained, exactly
# like a card that got a genuine reason comment after being discarded.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );

sub violations_for {
    my (%args) = @_;
    my $tira = Tira->new( clock => sub { $args{now} } );
    $tira->project_new(
        name => 'Discards', dir => $root, members => ['claude'],
        columns    => [ 'backlog', 'discard' ],
        sow_prefix => 'DCS', epic_prefix => 'DCE', ticket_prefix => 'DCT',
    );
    $tira->policy_add(
        project => $root, rule => 'discard-unexplained', action => 'log-only',
    );
    return $tira;
}

# --- the bug: an old, unrelated comment silently satisfies the rule --------

my $tira1 = violations_for( now => '2026-08-01T00:00:00Z' );
my $stale = $tira1->create_record( project => $root, type => 'ticket', title => 'Discarded after old chatter' );
$tira1->comment_add( project => $root, ref => $stale->{ref}, author => 'claude', text => 'unrelated early discussion' );

my $tira2 = Tira->new( clock => sub {'2026-08-15T00:00:00Z'} );
$tira2->record_move( project => $root, ref => $stale->{ref}, type => 'ticket', column => 'discard', author => 'claude' );

my $tira3 = violations_for( now => '2026-08-15T00:00:01Z' );
my $violations = $tira3->policy_evaluate( project => $root );
my @stale_hits = grep { ( $_->{rule} // '' ) eq 'discard-unexplained' && $_->{ref} eq $stale->{ref} } @{$violations};

ok( @stale_hits, 'a card discarded with only an OLD, unrelated comment is still flagged'
      . ' - if this list is empty, the rule is satisfied by any comment ever written,'
      . ' not one that actually explains the discard' );

# --- control: a genuine reason comment, written after the discard, clears it -

my $explained = $tira1->create_record( project => $root, type => 'ticket', title => 'Discarded with a real reason' );
$tira2->record_move( project => $root, ref => $explained->{ref}, type => 'ticket', column => 'discard', author => 'claude' );
$tira3->comment_add( project => $root, ref => $explained->{ref}, author => 'claude', text => 'duplicate of TKT-001, discarding' );

my $violations2 = $tira3->policy_evaluate( project => $root );
my @explained_hits = grep { ( $_->{rule} // '' ) eq 'discard-unexplained' && $_->{ref} eq $explained->{ref} } @{$violations2};
is( scalar @explained_hits, 0, 'a card discarded with a genuine reason comment, written after the discard, is not flagged' );

# --- control: no comment at all is flagged, same as before this fix --------

my $none = $tira1->create_record( project => $root, type => 'ticket', title => 'Discarded with nothing said' );
$tira2->record_move( project => $root, ref => $none->{ref}, type => 'ticket', column => 'discard', author => 'claude' );

my $violations3 = $tira3->policy_evaluate( project => $root );
my @none_hits = grep { ( $_->{rule} // '' ) eq 'discard-unexplained' && $_->{ref} eq $none->{ref} } @{$violations3};
ok( @none_hits, 'a card discarded with no comment at all is still flagged, same as before this fix' );

# --- an empty-body comment does not clear the rule either ---------------------
#
# TKT-638 decided this belonged here rather than at write time: "the rule below
# is where an empty explanation should be caught, not at write time", and left
# comment_add storing `body => text // ''` with no validation.
#
# THAT PRINCIPLE STILL HOLDS AND THIS TEST STILL PROVES IT. What changed is the
# door: since 5.43 comment_add REFUSES a whitespace-only body (TKT-753), so this
# block can no longer write one that way, and asserting the rule through a
# refused call would be asserting nothing.
#
# comment_update is the door now, and that is not a workaround - it is the
# reason TKT-753 left comment_update deliberately out of scope. A body can still
# arrive whitespace-only from an edit, from an import, from a board written by an
# older version, or from a migration. The rule has to catch it wherever it came
# from, which is exactly what TKT-638 argued. Writing it through the one path
# that still permits it makes that argument sharper than the original did: the
# rule is not relying on the writer being careful.

my $empty = $tira1->create_record( project => $root, type => 'ticket', title => 'Discarded with an empty comment' );
$tira2->record_move( project => $root, ref => $empty->{ref}, type => 'ticket', column => 'discard', author => 'claude' );
my $blanked = $tira3->comment_add( project => $root, ref => $empty->{ref},
    author => 'claude', text => 'placeholder, about to be blanked' );
$tira3->comment_update( project => $root, ref => $empty->{ref},
    comment => $blanked->{id}, text => '   ', author => 'claude' );

my $violations4 = $tira3->policy_evaluate( project => $root );
my @empty_hits = grep { ( $_->{rule} // '' ) eq 'discard-unexplained' && $_->{ref} eq $empty->{ref} } @{$violations4};
ok( @empty_hits, 'a post-discard comment that is only whitespace does not explain anything, and is still flagged' );

# --- control: comparison is by instant, not by string - a comment genuinely
# after the discard must still clear the rule even when its timestamp's
# offset spelling would sort earlier than the discard's as a plain string.
# Caught by Codex review before this card left verify: the first version of
# this fix compared 'created_at' and the discard timestamp with `ge`, which
# is wrong the moment the two use different offset spellings for the same
# instant or nearby instants.

my $tira_z    = Tira->new( clock => sub {'2026-08-20T23:00:00Z'} );
my $offset_card = $tira1->create_record( project => $root, type => 'ticket', title => 'Discarded across a timezone boundary' );
$tira_z->record_move( project => $root, ref => $offset_card->{ref}, type => 'ticket', column => 'discard', author => 'claude' );

# 2026-08-21T00:30:00+0500 is 2026-08-20T19:30:00Z by real instant - a full
# three and a half hours BEFORE the 2026-08-20T23:00:00Z discard above - but
# lexically "2026-08-21..." sorts AFTER "2026-08-20T23:00:00Z" as a plain
# string, because the date component alone (21 > 20) dominates a `ge`
# comparison regardless of what the offset takes back. A comment this stale
# must NOT clear the rule; the first version of this fix (raw string `ge`)
# got exactly this case wrong.
my $tira_stale = Tira->new( clock => sub {'2026-08-21T00:30:00+0500'} );
$tira_stale->comment_add( project => $root, ref => $offset_card->{ref}, author => 'claude', text => 'unrelated, predates the discard by real clock time' );

my $violations5 = $tira3->policy_evaluate( project => $root );
my @offset_hits = grep { ( $_->{rule} // '' ) eq 'discard-unexplained' && $_->{ref} eq $offset_card->{ref} } @{$violations5};
ok( @offset_hits,
    'a comment that is lexically "later" but actually predates the discard by real instant does NOT clear the rule - '
      . 'this is the case a raw string comparison of timestamps with different UTC offsets gets backwards' );

done_testing();

__END__

=head1 NAME

t/448-a-discard-that-explains-nothing-new.t - discard-unexplained must
read comments, not merely count them

=head1 DESCRIPTION

The rule's test was C<next if @{ $record->{comments} // [] }> - satisfied
by any comment a card ever had, including one written long before the
discard and about something else entirely. Fixed to require a comment
written at or after the move into discard, with a non-empty body. TKT-638.

=cut
