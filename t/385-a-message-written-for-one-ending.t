#!/usr/bin/env perl
# TKT-406. "Verified on the installed 2.69: a card that reaches done with an
# open question is correctly reported, but the message still says 'ask the
# ones that do on the card they belong to now, and discard them here.'
# Wording written for the discard case, now also shown for done. Not a
# functional gap; the finding is correct and named."
#
# "discard them here" is about discarding the leftover QUESTIONS
# (tira.question.discard), which is accurate on any ending column - the
# genuinely stale part is the opening "set aside carrying...", which
# specifically implies the CARD was discarded when it may simply have
# finished.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T15:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Endings', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'END', epic_prefix => 'ENE', ticket_prefix => 'ENT',
);
my $store = File::Spec->catdir( $tmp, 'police-store' );

$tira->policy_add( project => $root, rule => 'discard-with-open-questions', action => 'bridge-reminder' );

sub reported {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq 'discard-with-open-questions' } @{ $pass->{violations} } ];
}

# --- a card that reached done says so, not that it was set aside ------------
my $finished = $tira->create_record( project => $root, type => 'ticket', title => 'Finished with a loose end' );
$tira->question_add( project => $root, ref => $finished->{ref}, author => 'claude', text => 'Still relevant?' );
$tira->record_move( author => 'claude', project => $root, ref => $finished->{ref}, column => 'done' );

my @done_found = @{ reported() };
is( scalar @done_found, 1, 'a card that reached done with an open question is reported' );
like( $done_found[0]{detail}, qr/\Areached done carrying/, 'and the message names the column it actually reached' );
unlike( $done_found[0]{detail}, qr/set aside/, 'not that it was set aside - it was not' );
like( $done_found[0]{detail}, qr/discard them here/, 'still says to discard the question here - that part was always accurate' );

# --- a discarded card keeps today's exact wording ----------------------------
my $shelved = $tira->create_record( project => $root, type => 'ticket', title => 'Actually set aside' );
$tira->question_add( project => $root, ref => $shelved->{ref}, author => 'claude', text => 'Worth keeping?' );
$tira->record_discard( author => 'claude', project => $root, ref => $shelved->{ref} );

my @discard_found = grep { $_->{ref} eq $shelved->{ref} } @{ reported() };
is( scalar @discard_found, 1, 'a discarded card with an open question is still reported' );
like( $discard_found[0]{detail}, qr/\Aset aside carrying/, 'and its message is unchanged - still says set aside' );

done_testing;

__END__

=head1 NAME

385-a-message-written-for-one-ending.t - discard-with-open-questions names the ending it actually reached

=head1 DESCRIPTION

TKT-406: discard-with-open-questions already fires correctly on any ending
column, not just discard - the finding was never wrong, only the message,
which said "set aside carrying..." even for a card that reached done. The
opening now names the actual column reached ("set aside" for discard,
"reached COLUMN" otherwise); the "discard them here" phrasing about the
leftover questions is unchanged in both cases, since discarding a question
is valid regardless of the card's own column.
