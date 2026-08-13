#!/usr/bin/env perl
# A question command acts on the card you named, or on none.
#
# Every question command resolves the question by id alone and then overwrites
# whatever ref the caller gave:
#
#   my ( $found_type, $found_ref ) = $self->_find_question( $root, $args{id} );
#   @args{qw(type ref)} = ( $found_type, $found_ref );
#
# So answering with one card's ref and another card's id answers the other
# card, returns the answer, and exits zero. The card that was named is left
# waiting.
#
# It is silent in both directions. The caller sees success, and the board looks
# consistent afterwards, because the answer really is on a card - nothing
# anywhere says it is on the wrong one. That is how a broken fixture was built
# without noticing: a loop answered --id Q-001 on a card whose question was
# Q-002, and quietly answered the first card twice.
#
# Resolving by id alone stays: the ids are unique across a board and an agent
# should not have to say which card. What must not happen is a ref being given
# and thrown away.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T04:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Whose question', dir => $root, members => [ 'michael', 'ada' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WQS', epic_prefix => 'WQE', ticket_prefix => 'WQT',
);

my $first = $tira->create_record( project => $root, type => 'ticket', title => 'First card' );
my $second = $tira->create_record( project => $root, type => 'ticket', title => 'Second card' );

my $hers = $tira->question_add( project => $root, ref => $first->{ref}, author => 'ada',
    text => 'A question on the first card', reason => 'because' );
my $his = $tira->question_add( project => $root, ref => $second->{ref}, author => 'ada',
    text => 'A question on the second card', reason => 'because' );

isnt( $hers->{id}, $his->{id}, 'question ids are unique across the board, which is why id alone resolves' );

# --- naming the wrong card ------------------------------------------------

my $refused = !eval {
    $tira->question_answer( project => $root, ref => $second->{ref}, id => $hers->{id},
        text => 'aimed at the second card' );
    1;
};
ok( $refused, 'answering with one card and another card\'s question is refused' );
like( $@, qr/\Q$hers->{id}\E/, 'and the refusal names the question' );
like( $@, qr/\Q$first->{ref}\E/, 'and the card it actually belongs to, so the fix is obvious' );

my $untouched = $tira->record_show( project => $root, ref => $first->{ref} );
is( ( $untouched->{questions}[0]{answer} // {} )->{text}, undef,
    'and the card that was not named is not changed - a refusal that half happened is worse than none' );

# --- naming no card at all ------------------------------------------------
#
# The convenience that made this possible, and it stays: the ids are unique, so
# an agent should not have to say which card a question is on.

my $answered = $tira->question_answer( project => $root, id => $hers->{id},
    text => 'aimed at nothing in particular' );
is( $answered->{answer}{text}, 'aimed at nothing in particular',
    'with no card named, the id resolves as before' );
is( $tira->record_show( project => $root, ref => $first->{ref} )->{questions}[0]{answer}{text},
    'aimed at nothing in particular', 'and it lands on the card that owns the question' );

# --- naming the right card ------------------------------------------------
#
# So that nothing which was correct yesterday becomes an error today.

my $agreed = $tira->question_answer( project => $root, ref => $second->{ref}, id => $his->{id},
    text => 'aimed correctly' );
is( $agreed->{answer}{text}, 'aimed correctly', 'naming the card the question is on is accepted' );

# --- and all six behave the same ------------------------------------------
#
# Six commands that agree today drift apart the first time somebody fixes only
# the one they were looking at, which is the fault this project found in its
# own program lookup two releases ago.

for my $command (
    [ question_mark    => { mark => 'ok' } ],
    [ question_discard => {} ],
    [ question_update  => { text => 'reworded' } ],
    [ question_voice   => { remove => 1 } ],
) {
    my ( $name, $extra ) = @{$command};
    my $stopped = !eval {
        $tira->$name( project => $root, ref => $first->{ref}, id => $his->{id}, %{$extra} );
        1;
    };
    ok( $stopped, "$name refuses a card that does not own the question" );
    like( $@, qr/\Q$second->{ref}\E/, "and $name says where it really is" );
}

done_testing();

__END__

=head1 NAME

120-question-belongs-to-its-card.t - a question command acts on the card you named

=head1 DESCRIPTION

Every question command resolved the question by id and then overwrote the ref
the caller gave, so naming one card and another card's question changed the
other card and reported success. The card that was named stayed waiting, and
nothing anywhere said the answer had landed somewhere else.

Resolving by id alone stays, because the ids are unique across a board and an
agent should not have to say which card. A ref that is given and disagrees is
now refused, naming both the question and the card it really belongs to.

=cut
