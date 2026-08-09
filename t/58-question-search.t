#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-09T09:00:00Z' } );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Findable', dir => $root, columns => ['Backlog, Doing'],
    sow_prefix => 'FDS', epic_prefix => 'FDE', ticket_prefix => 'FDT',
);
my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Importer' );
my $epic = $tira->create_record( project => $root, type => 'epic', title => 'Migration' );
my $quiet = $tira->create_record( project => $root, type => 'ticket', title => 'Nothing asked here' );

$tira->question_add( project => $root, ref => $ticket->{ref},
    text => 'Which credentials should the loader use?' );
my $on_epic = $tira->question_add( project => $root, ref => $epic->{ref},
    text => 'Does this cover the archive?' );
$tira->question_answer( project => $root, id => $on_epic->{id},
    text => 'Only the live tables, not the archive.' );

sub refs_for {
    my ($text) = @_;
    return $tira->search( project => $root, text => $text, refs_only => 1 );
}

# The words in a question find the card it was asked on.
is_deeply( refs_for('credentials'), [ $ticket->{ref} ], 'question text finds its card' );

# So do the words in the answer.
is_deeply( refs_for('archive'), [ $epic->{ref} ],
    'answer text finds its card, and the question that asked it' );

# And the reference itself, which is the point: it belongs to the project.
is_deeply( refs_for( $on_epic->{id} ), [ $epic->{ref} ],
    'a question reference finds the card it lives on' );
is( $on_epic->{id}, 'Q-002', 'even though nobody said which board it was on' );

# A card nobody asked about stays out of it.
ok( !grep( { $_ eq $quiet->{ref} } @{ refs_for('credentials') } ),
    'a card with no questions is not dragged in' );

# Discarding hides nothing: it still happened.
$tira->question_discard( project => $root, id => $on_epic->{id} );
is_deeply( refs_for( $on_epic->{id} ), [ $epic->{ref} ],
    'a discarded question is still findable, because it still happened' );
is_deeply( refs_for('archive'), [ $epic->{ref} ], 'and so is its answer' );

# What was already searchable still is.
is_deeply( refs_for('Importer'), [ $ticket->{ref} ], 'titles still match' );
is_deeply( refs_for( $ticket->{ref} ), [ $ticket->{ref} ], 'card references still match' );

# A card that cannot be parsed must not stop a question being found on another
# one: half a board is still better than none.
{
    my $rubbish = File::Spec->catfile( $root, '.tira', 'ticket', 'backlog', 'FDT-999.json' );
    open my $fh, '>:raw', $rubbish or die $!;
    print {$fh} '{ this is not json at all';
    close $fh;
    is_deeply(
        [ $tira->_find_question( $root, $on_epic->{id} ) ], [ 'epic', $epic->{ref} ],
        'an unreadable card does not stop a question being found' );
    unlink $rubbish or die $!;
}

done_testing;

__END__

=head1 NAME

58-question-search.t - DD-472 questions are searchable

=head1 DESCRIPTION

A question reference belongs to the project rather than to a board, so
quoting one has to find the card it lives on without anybody
remembering which board that was. Proves search matches a question's
text, its answer's text and its reference, alongside everything it
matched before, and that discarding a question hides none of it,
because it still happened.

=cut
