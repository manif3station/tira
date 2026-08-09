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
$tira->project_new( name => 'Counting', dir => $root, members => ['ada'], columns => ['Backlog, Doing'],
    sow_prefix => 'CNS', epic_prefix => 'CNE', ticket_prefix => 'CNT' );

sub file_at {
    my ( $name, $bytes ) = @_;
    my $path = File::Spec->catfile( $tmp, $name );
    open my $fh, '>:raw', $path or die $!;
    print {$fh} $bytes;
    close $fh;
    return $path;
}

# A file on a card can live in three places. The count used to look in one, so
# a card whose files hung off comments reported zero - and another agent read
# that zero as failure and went hunting for a bug that was not there.
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Has files everywhere' );

my $comment = $tira->comment_add(
    project => $root, ref => $card->{ref}, author => 'ada', text => 'See the recording' );
$tira->comment_attach( project => $root, ref => $card->{ref},
    comment => $comment->{id}, file => file_at( 'log.txt', 'a log' ) );

my $only_comments = $tira->attachment_list( project => $root, ref => $card->{ref}, count => 1 );
is( $only_comments->{count}, 1,
    'a card whose only file hangs off a comment does not report zero' );

my $question = $tira->question_add(
    project => $root, ref => $card->{ref}, text => 'Which one?',
    voice => file_at( 'ask.ogg', 'OggS-audio' ) );
is( $tira->attachment_list( project => $root, ref => $card->{ref}, count => 1 )->{count}, 2,
    'a voice note on a question counts too, because it is a file on this card' );

$tira->attachment_add_content( project => $root, ref => $card->{ref},
    filename => 'oncard.txt', content => 'on the card' );
is( $tira->attachment_list( project => $root, ref => $card->{ref}, count => 1 )->{count}, 3,
    'and all three are counted together' );

# Each says where it is, because "three files" without "where" just moves the
# hunt somewhere else.
my $detailed = $tira->attachment_list( project => $root, ref => $card->{ref}, meta_only => 1 );
my %where = map { ( $_->{original_filename} // $_->{filename} // '' ) => $_->{attached_to} }
  @{ $detailed->{attachments} };
is( $where{'oncard.txt'}, 'card', 'a card attachment says so' );
is( $where{'log.txt'}, "comment $comment->{id}", 'a comment attachment names its comment' );
is( $where{'ask.ogg'}, "question $question->{id}", 'and a voice note names its question' );

# The plain list agrees with the count, or one of them is lying.
my $plain = $tira->attachment_list( project => $root, ref => $card->{ref} );
is( scalar @{$plain}, $detailed->{count}, 'the plain list and the count agree' );

# A card with nothing really does have nothing.
my $empty = $tira->create_record( project => $root, type => 'ticket', title => 'Genuinely empty' );
is( $tira->attachment_list( project => $root, ref => $empty->{ref}, count => 1 )->{count}, 0,
    'a card with no files anywhere still reports zero, which is now the truth' );

# Discarding a question does not hide its recording: the file is still there.
$tira->question_discard( project => $root, id => $question->{id} );
is( $tira->attachment_list( project => $root, ref => $card->{ref}, count => 1 )->{count}, 3,
    'a discarded question keeps its recording counted, because the file still exists' );

done_testing;

__END__

=head1 NAME

69-attachment-count.t - DD-493 counting files wherever they actually are

=head1 DESCRIPTION

A file on a card can be attached to the card, to a comment, or to a
question as a voice note. The count looked only at the first, so a card
whose files hung off comments reported zero; another agent read that as
failure and went looking for a bug that did not exist. Proves all three
places are counted, that each entry says where it was found, and that a
card reporting zero now genuinely has nothing.

=cut
