#!/usr/bin/env perl
# TKT-829, found by the two-hourly improvement hunt on 2026-09-01 by reading
# the code TKT-687 had just shipped rather than by any failure.
#
# THE CAP IS CHECKED BEFORE THE STRING BECOMES BYTES:
#
#   Attachment.pm:112   die "... too large (16 MB maximum)" if length($content) > 16 * 1024 * 1024;
#   Attachment.pm:124   $content = encode_utf8($content) if utf8::is_utf8($content);
#
# Twelve lines apart, and in that order. For a Perl character string,
# length() counts CHARACTERS, so a proof made of 4-byte UTF-8 - emoji, CJK,
# an accented name - passes a 16 MB cap while writing up to 64 MB to disk.
#
# TKT-687 IS WHAT MADE IT REACHABLE. Before it, long non-ASCII content died in
# Digest::SHA with "Wide character in subroutine entry"; that card encoded to
# bytes first so such content would be accepted, and accepting it is what lets
# a character count reach the cap in the first place. The fix composes with
# TKT-687 rather than undoing it: the same encode line simply has to run
# BEFORE the size die instead of after it.
#
# THE CITATION IN THE CARD HAD DRIFTED FURTHER THAN A LINE NUMBER: it says
# lib/Tira.pm:4356, and this sub is not in lib/Tira.pm at all any more - it was
# lifted to lib/Tira/Attachment.pm, leaving a one-line forwarder behind. Both
# were re-measured before anything was written.
#
# THE SIBLING CHECK IS CORRECT AND STAYS: _store_attachment_file caps the same
# way at Attachment.pm:75, but reads its content with '<:raw', so the string is
# already bytes and length() is already counting them. One instance, not two -
# checked rather than assumed, and asserted below so a later change to that
# read cannot quietly make it two.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;

my $CAP = 16 * 1024 * 1024;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $tira = Tira->new( clock => sub {'2026-09-06T15:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Wide Cap', dir => $root, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'WCS', epic_prefix => 'WCE', ticket_prefix => 'WCT',
    );
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'something to attach to' );
    return ( $tira, $root, $card->{ref} );
}

sub add_content {
    my ( $tira, $root, $ref, $filename, $content ) = @_;
    my $ok = eval {
        $tira->attachment_add_content( project => $root, ref => $ref,
            filename => $filename, content => $content, author => 'claude' );
        1;
    };
    return ( $ok, $@ // '' );
}

# --- a multi-byte proof over the byte cap is refused ------------------------
#
# The whole card, and the size is chosen to make the two counts disagree
# rather than to be large: 4,194,305 emoji is 4.2 million CHARACTERS, well
# under the cap, and 16,777,220 BYTES, just over it. Before the fix the first
# number is the one that was measured.

{
    my ( $tira, $root, $ref ) = board();
    my $emoji = "\x{1F600}" x ( $CAP / 4 + 1 );

    cmp_ok( length($emoji), '<', $CAP,
        'the content is under the cap when counted in characters' );

    my ( $ok, $why ) = add_content( $tira, $root, $ref, 'proof.txt', $emoji );
    ok( !$ok,
        'and is REFUSED, because what reaches the disk is four bytes per character - the '
          . 'cap has to measure the thing being written, not the thing being counted' );
    like( $why, qr/too large/,
        'with the size refusal it was always meant to give, rather than some later failure' );
    like( $why, qr/16 MB maximum/, 'naming the limit' );
    like( $why, qr/this is 16\.0 MB/,
        'and naming the size it actually measured - which after this card is no longer a '
          . 'number the caller can count for themselves, since what is measured is the '
          . 'ENCODED length and theirs was a quarter of it' );
}

# --- an ASCII string over the cap is refused exactly as before ---------------
#
# The regression that matters most: for a byte string the two counts are the
# same number, so the existing behaviour must come through untouched.

{
    my ( $tira, $root, $ref ) = board();
    my $ascii = 'x' x ( $CAP + 1 );

    my ( $ok, $why ) = add_content( $tira, $root, $ref, 'proof.txt', $ascii );
    ok( !$ok, 'a plain ASCII string one byte over the cap is still refused' );
    like( $why, qr/too large/, 'with the same message' );
}

# --- and ordinary content still stores ---------------------------------------
#
# The other direction a careless reorder breaks: the encode has to keep
# happening, and a normal attachment must be unaffected by any of this.

{
    my ( $tira, $root, $ref ) = board();
    my ( $ok, $why ) = add_content( $tira, $root, $ref, 'note.txt',
        "a short proof with an em dash \x{2014} and an emoji \x{1F600}" );
    ok( $ok, 'a short non-ASCII proof still stores' ) or diag($why);

    my $stored = $tira->attachment_list( project => $root, ref => $ref );
    is( scalar @{$stored}, 1, 'and is on the card afterwards' );
}

# --- the cap is measured after the encode, in the source ---------------------
#
# Read from the source because the behavioural assertions above can be
# satisfied by a second cap bolted on top, and this card is about the ORDER of
# two lines that already exist.

{
    # THE ENGINE WALKER, NOT THE CLI ONE. Attachment.pm lives at
    # lib/Tira/Attachment.pm, which cli_source deliberately excludes - it walks
    # lib/Tira/CLI only. Asking it for this file returned the whole command
    # surface instead, which is non-empty, so the "is it there to be read"
    # check passed on the WRONG TEXT while every claim under it failed. Caught
    # by running it, and the reason it is worth a comment: a source walker that
    # answers with somebody else's file is the "absence proven by a broken
    # instrument" fault wearing its opposite face.
    my $attach = Suite::engine_source();
    # non-empty is the whole claim: every check below would pass on an
    # unreadable file's emptiness alone.
    like( $attach, qr/\S/, 'the engine source is there to be read' );

    # THE DEFINITION, NOT THE FORWARDER. lib/Tira.pm still carries a one-line
    # sub attachment_add_content that delegates to this module, and it sorts
    # first in the walk - so a match anchored only on the name ran from the
    # forwarder to some later sub's closing brace and contained neither the cap
    # nor the encode. Requiring a newline straight after the brace picks the
    # real definition, because the forwarder's whole body is on its own line.
    # This is the same drift that made the card's own citation point at a file
    # the code had left, arriving one level down in the test that was written
    # about it.
    my ($sub) = $attach =~ /(sub \s+ attachment_add_content \s* \{\n .*? \n\})/xs;
    like( $sub // '', qr/16 \* 1024 \* 1024/,
        'attachment_add_content was found, and is the one carrying the cap' );

    my $encode_at = index( $sub // '', 'encode_utf8' );
    my $cap_at    = index( $sub // '', '16 * 1024 * 1024' );
    cmp_ok( $encode_at, '>', -1, 'it encodes its content to bytes' );
    cmp_ok( $cap_at,    '>', -1, 'and it caps the size' );
    cmp_ok( $encode_at, '<', $cap_at,
        'and the encode happens BEFORE the cap - which is the whole fix, since the two '
          . 'lines already existed and only their order was wrong' );
}

# --- the sibling cap reads bytes already and is left alone -------------------
#
# _store_attachment_file caps the same way, and correctly: it reads with
# '<:raw', so its content is a byte string and length() is already counting
# bytes. Asserted rather than assumed, so a later change to that read cannot
# quietly turn one instance into two.

{
    my $attach = Suite::engine_source();
    my ($sub) = $attach =~ /(sub \s+ _store_attachment_file \s* \{\n .*? \n\})/xs;
    like( $sub // '', qr/16 \* 1024 \* 1024/,
        'the file-storing path was found, and it carries the same cap' );
    like( $sub // '', qr/<:raw/,
        'and it reads its content as raw bytes, which is why counting characters there '
          . 'is already counting bytes - one instance of this fault, not two' );
}

done_testing();

__END__

=head1 NAME

579-a-cap-that-counts-the-wrong-thing.t - the attachment cap measures the bytes it will write

=head1 DESCRIPTION

TKT-829. C<attachment_add_content> checked its 16 MB cap with C<length()>
twelve lines before encoding the content to UTF-8 bytes, so a character string
of 4-byte characters passed a cap it exceeded fourfold. TKT-687 is what made
that reachable: before it, such content died in C<Digest::SHA>, and accepting
it is what lets a character count reach the cap at all.

The fix is the order of two lines that already existed. The sibling cap in
C<_store_attachment_file> is correct as written, because it reads its content
with C<< <:raw >> and is therefore already counting bytes - asserted here so a
later change to that read cannot quietly make this fault two instances.

=cut
