use strict;
use warnings;
use Test::More;
use File::Spec;
use FindBin qw($Bin);

# TKT-790: README.md gains real screenshots (terminal output, dashboard
# board view, card-detail modal) each with a one-line caption, instead of
# being purely textual. This asserts the images exist on disk and are
# referenced with captions in README.md, not just that files were dropped
# into docs/images/ unused.

my $root   = File::Spec->catdir( $Bin, File::Spec->updir );
my $readme = File::Spec->catfile( $root, 'README.md' );

open my $fh, '<', $readme or die "cannot open $readme: $!";
local $/;
my $text = <$fh>;
close $fh;

my @images = (
    [ 'docs/images/terminal-example.png',      qr/terminal/i ],
    [ 'docs/images/dashboard-board.png',       qr/board/i ],
    [ 'docs/images/dashboard-card-modal.png',  qr/modal|card/i ],
    [ 'docs/images/dashboard-card-modal-attachments.png', qr/attachment|linkage|modal/i ],
);

for my $pair (@images) {
    my ( $rel, $caption_re ) = @$pair;
    my $path = File::Spec->catfile( $root, split m{/}, $rel );
    ok( -e $path, "$rel exists on disk" );

    ok( index( $text, $rel ) >= 0, "README.md references $rel" )
        or diag("expected README.md to embed $rel via markdown image syntax");

    # A visible caption is a line of its own directly below the image,
    # not the image's alt text - GitHub does not render alt text visibly.
    if ( $text =~ /!\[[^\]]*\]\(\Q$rel\E\)\n(\*[^\n]+\*)\n/ ) {
        my $caption = $1;
        like( $caption, $caption_re, "$rel has a visible caption matching $caption_re" );
        ok( length($caption) > 2, "$rel caption is not empty" );
    }
    else {
        fail("$rel has no visible one-line caption on the line right after the image");
    }
}

done_testing();

__END__

=head1 NAME

t/463-a-readme-that-shows-instead-of-tells.t

=head1 DESCRIPTION

C<README.md> was purely textual. TKT-790 added four real screenshots,
captured from a throwaway non-production scratch project: terminal
output of C<tira.police> and C<tira.ticket.show>, the ticket board
rendered by C<-o browser>, and the card-detail modal in two states
(its top fields, then scrolled down to linkage and attachments) - each
followed by its own one-line italic caption line, not just alt text
(GitHub does not render Markdown image alt text visibly). This file
asserts each image exists on disk, is referenced from C<README.md>,
and has a real, non-empty visible caption naming what it shows.

=cut
