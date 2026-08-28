#!/usr/bin/env perl

# A program attached to a card cannot be read from the board.
#
# TKT-645, and the owner hit it himself: he had asked for the reference
# implementation to be attached to TKT-639, it was, and then the viewer
# answered "Preview is not supported for this file in this browser. Use the
# Download button above to open it locally." for a shell script sitting on the
# card he was reading.
#
# TWO ALLOWLISTS, NOT ONE, AND THE CARD NAMES ONLY THE BROWSER'S. The viewer
# keeps textExts={txt,md,log,csv,json,yml,yaml,xml,html}. The engine keeps the
# identical nine in _attachment_content_type and serves everything else as
# application/octet-stream. So a .pl attachment is refused by the viewer AND
# called binary by the server, and widening one list would leave the other
# disagreeing about the same file for ever.
#
# That is the fourth instance in a day of one shape - a second implementation
# of something that already exists - after TKT-639, TKT-671, TKT-681 and
# TKT-657. So the fix follows the answer those reached: the ENGINE decides
# whether an attachment is text, and the viewer asks. The attachment payload
# already carries content_type; the browser simply is not using it.
#
# The control that stops the obvious over-correction is the last one here. A
# fix that showed everything as text would satisfy every assertion above it and
# break the card's fourth acceptance criterion, which is that a genuinely
# binary attachment must still refuse rather than render as mojibake.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Tira;

# --- the engine already knows some things are text --------------------------
#
# An anchor. Without it the failures below read as "the engine has no idea what
# text is" rather than "its list is too short".

is( Tira::_attachment_content_type('md'), 'text/plain; charset=UTF-8',
    'a markdown attachment is served as text, as it always has been' );
is( Tira::_attachment_content_type('png'), 'image/png',
    'and an image is still an image - widening text must not swallow the other kinds' );

# --- the languages the card names -------------------------------------------
#
# Perl, Python, Java, Go, Rust, PHP, JavaScript, CSS, C and C++, plus the shell
# script the owner was actually trying to read. HTML and XML are the two of the
# twelve already in the list, which is why they are not repeated here.

for my $ext (qw(pl pm py java go rs php js css c h cpp sh)) {
    like( Tira::_attachment_content_type($ext), qr{^text/},
        "a .$ext attachment is served as text, so the board can show it" );
}

# --- and a binary is still a binary -----------------------------------------
#
# The control, and the one that matters most after the fix rather than before
# it. Every assertion above is satisfied by "call everything text"; only this
# one fails, and the card's fourth acceptance criterion is exactly that a
# genuinely binary attachment still refuses rather than rendering as mojibake.

for my $ext (qw(zip tar gz bin exe o so wasm)) {
    is( Tira::_attachment_content_type($ext), 'application/octet-stream',
        "a .$ext attachment is still binary - widening text must not swallow it" );
}

# --- and an extension nobody anticipated is decided by looking --------------
#
# This is what makes the widening a DEFAULT rather than a longer list. The two
# lists above exist to answer the cases where guessing would be worse than
# knowing - a .pl file is Perl whatever its first bytes look like, and an empty
# one is still text. Everything else is read.

use File::Temp qw(tempdir);
use File::Spec;
my $scratch = tempdir( CLEANUP => 1 );

sub written {
    my ( $name, $bytes ) = @_;
    my $path = File::Spec->catfile( $scratch, $name );
    open my $fh, '>:raw', $path or die "$path: $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

is( Tira::_attachment_content_type( 'zzz', written( 'a.zzz', "#!/usr/bin/env tclsh\nputs hello\n" ) ),
    'text/plain; charset=UTF-8',
    'an extension nobody listed is shown when its bytes read as text' );
is( Tira::_attachment_content_type( 'zzz', written( 'b.zzz', "PK\x03\x04\x00\x00rubbish\x00\x01\x02" ) ),
    'application/octet-stream',
    'and refused when they do not - a NUL byte is the oldest test there is' );
is( Tira::_attachment_content_type( 'zzz', undef ),
    'application/octet-stream',
    'an unknown extension with nothing to examine refuses, rather than guessing text' );
is( Tira::_attachment_content_type( 'zzz', written( 'c.zzz', '' ) ),
    'application/octet-stream',
    'and so does an empty one - there is nothing there to call text' );
is( Tira::_attachment_content_type( 'zzz', File::Spec->catfile( $scratch, 'not-here.zzz' ) ),
    'application/octet-stream',
    'a path that does not exist refuses rather than dying' );

# --- one definition, asked rather than copied -------------------------------
#
# Read rather than run, the way t/224 and t/416 already assert things about
# readers they cannot execute. The viewer must stop keeping its own list: two
# tables of the same nine extensions is what put the engine and the browser in
# disagreement about one file.

my $dash = do {
    open my $fh, '<', 'lib/Tira.pm' or die "Tira.pm: $!";
    local $/;
    <$fh>;
};

ok( $dash,
    'lib/Tira.pm was read before anything is denied about it - '
      . length($dash)
      . ' bytes, so the denial below is about the real file rather than '
      . 'about an empty string' );

unlike( $dash, qr/textExts=\{txt:1/,
    'the viewer keeps no extension allowlist of its own for text' );

done_testing();

__END__

=head1 NAME

t/423-a-file-the-board-will-not-show-you.t - a source file attached to a card
must be readable from the board

=head1 DESCRIPTION

The attachment viewer previewed nine text extensions and refused everything
else, so a program attached to a card could not be read at all - which the
owner hit on a shell script he had asked to be attached to another card.

The nine-extension list exists twice: once in the inlined dashboard JS and once
in C<_attachment_content_type>, which serves anything else as
C<application/octet-stream>. Widening one would leave the other calling the same
file binary, so the fix makes the engine the single decider and has the viewer
ask - the same arrangement TKT-224, TKT-671, TKT-681 and TKT-657 each arrived at
for their own duplicated readers.

The last assertions are the ones that matter after the fix rather than before
it. A change that called everything text would satisfy every language assertion
here and break the card's fourth acceptance criterion, which is that a genuinely
binary attachment still refuses rather than rendering as mojibake.

=cut
