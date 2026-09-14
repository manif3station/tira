#!/usr/bin/env perl

# _attachment_content_type decides type and charset in the same line, and
# only the type half was thought through on TKT-645. A file whose bytes are
# not valid UTF-8 - a Latin-1 source saved on a machine that never defaults
# to UTF-8 - still comes back labelled 'text/plain; charset=UTF-8', so a
# viewer that trusts the header decodes it wrong and shows replacement
# characters for real ones.
#
# The named-extension path (a .pl, a .md, ...) never reads the file at all,
# so it cannot know the charset either way - TKT-707's own description
# names this as the design question to answer, and the safer of its two
# named options is the one taken here: omit the charset when nothing has
# looked, rather than guessing UTF-8 for bytes never read.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

use lib 'lib';
use Tira;

my $scratch = tempdir( CLEANUP => 1 );

sub written {
    my ( $name, $bytes ) = @_;
    my $path = File::Spec->catfile( $scratch, $name );
    open my $fh, '>:raw', $path or die "$path: $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

# --- the sniff path has the bytes in hand, and must actually check them ----

{
    # A single accented character in Latin-1: 0xE9 is 'é' in that encoding,
    # but is not valid UTF-8 on its own - a lone continuation-shaped byte
    # with nothing to continue.
    my $latin1 = written( 'note.zzz', "Caf\xe9 con leche\n" );
    is( Tira::_attachment_content_type( 'zzz', $latin1 ), 'text/plain',
        'a Latin-1 file is still served as text, but without a UTF-8 charset claim that would misrender it' );
}

{
    my $utf8 = written( 'note2.zzz', "Caf\x{c3}\x{a9} con leche\n" );
    is( Tira::_attachment_content_type( 'zzz', $utf8 ), 'text/plain; charset=UTF-8',
        'a genuinely UTF-8 file with accented characters still claims the charset - the case that must not regress' );
}

# --- the named-extension path never reads the file, and says so honestly --

{
    my $latin1_named = written( 'note.md', "Caf\xe9 con leche\n" );
    is( Tira::_attachment_content_type( 'md', $latin1_named ), 'text/plain',
        'a named text extension whose bytes happen to be Latin-1 is not claimed as UTF-8 either' );
}

# --- the check covers the whole file, not just the first 8KB sniff sample --
#
# Codex review: an earlier draft reused _attachment_head's 8KB sniff sample
# for the charset check too, so an invalid byte anywhere past that boundary
# was still served as charset=UTF-8 - the exact bug this ticket exists to
# remove, only moved further into the file.

{
    my $big_then_invalid = written( 'past-boundary.zzz', ( 'a' x 8192 ) . "\xe9\n" );
    is( Tira::_attachment_content_type( 'zzz', $big_then_invalid ), 'text/plain',
        'an invalid byte past the 8KB sniff boundary still refuses the UTF-8 claim' );
}

{
    my $big_named = written( 'past-boundary.md', ( 'a' x 8192 ) . "\xe9\n" );
    is( Tira::_attachment_content_type( 'md', $big_named ), 'text/plain',
        'the same is true for the named-extension path' );
}

done_testing;

__END__

=head1 NAME

1093-a-charset-that-guessed-wrong.t - a text attachment's charset describes what was actually observed

=head1 DESCRIPTION

TKT-707. C<_attachment_content_type> claimed C<charset=UTF-8> for every text
attachment regardless of whether its bytes were ever checked (the
named-extension path never reads the file) or, having been read for the
sniff path, were actually valid UTF-8. A Latin-1 source file rendered as
mojibake in any viewer that trusted the header. Both paths now omit the
charset unless UTF-8 validity was actually confirmed.

=cut
