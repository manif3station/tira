#!/usr/bin/env perl
# tira.question.list was the only way to see a question, and opening it set
# read_at - so checking whether an answer had been read was the same act as
# reading it. A manager routing work down a chain who opened a question to
# route it consumed the one detector whose entire job was to send that agent
# there, permanently. --peek returns metadata only (id, status, answered_at,
# read_at, mark - never the answer text) and does not itself mark anything
# read, so checking and settling stop being the same keystroke. TKT-336.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tira = Tira->new( clock => sub {'2026-08-23T09:00:00Z'} );
my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Peeked', dir => $root, members => ['claude'],
    sow_prefix => 'PKS', epic_prefix => 'PKE', ticket_prefix => 'PKT',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Carries a question' );
my $question = $tira->question_add( project => $root, ref => $card->{ref},
    text => 'Which way?', reason => 'A reason worth reading.', options => [ 'A', 'B' ] );
$tira->question_answer( project => $root, ref => $card->{ref},
    id => $question->{id}, text => 'Go with A - context that matters.', author => 'michael' );

# --- peeking returns metadata, never the answer text -----------------------------

{
    my $peeked = $tira->question_list( project => $root, ref => $card->{ref}, peek => 1 );
    my ($seen) = @{ $peeked->{questions} };
    is( $seen->{id}, $question->{id}, 'peek names the question' );
    is( $seen->{status}, 'answered', 'and its status' );
    ok( $seen->{answered_at}, 'and when it was answered' );
    is( $seen->{read_at}, undef, 'read_at is null - peeking has not read it' );
    is( $seen->{mark}, undef, 'and mark, unset' );
    ok( !exists $seen->{answer}, 'the answer TEXT is withheld entirely' );
    ok( !exists $seen->{reason}, 'and the reason' );
    ok( !exists $seen->{options}, 'and the options - metadata only' );
}

# --- peeking twice never sets read_at, unlike the real list -----------------------

{
    $tira->question_list( project => $root, ref => $card->{ref}, peek => 1 );
    my $peeked_again = $tira->question_list( project => $root, ref => $card->{ref}, peek => 1 );
    is( $peeked_again->{questions}[0]{read_at}, undef,
        'peeking twice in a row still leaves read_at null' );
}

# --- the real, non-peeking list still marks it read, exactly as before -----------

{
    my $real = $tira->question_list( project => $root, ref => $card->{ref} );
    ok( $real->{questions}[0]{answer}{read_at}, 'the real list marks the answer read, as it always has' );
    ok( $real->{questions}[0]{answer}{text}, 'and returns the answer text, unlike peek' );
}

# --- and once truly read, a later peek reports that too --------------------------

{
    my $peeked_after = $tira->question_list( project => $root, ref => $card->{ref}, peek => 1 );
    ok( $peeked_after->{questions}[0]{read_at}, 'a peek after a real read reports read_at, honestly' );
}

done_testing;

__END__

=head1 NAME

337-a-peek-that-does-not-read.t - question.list --peek inspects without marking

=head1 DESCRIPTION

C<tira.question.list> was the only way to see a question, and reading it is
what marks its answer read - so checking whether an answer had been read
was the same act as reading it. C<--peek> returns metadata only (C<id>,
C<status>, C<answered_at>, C<read_at>, C<mark> - never the answer text,
reason, or options) and does not itself mark anything read, so a manager
routing work down a chain can check state without destroying the very
signal meant for whoever is supposed to act on it. TKT-336.

=cut
