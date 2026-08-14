#!/usr/bin/env perl
# An add that cannot take is refused, not reported as done.
#
# zen-framework discarded twenty-two screenshots believing all of them had
# changed. Ten had not. Re-adding the identical bytes deduped onto the discarded
# record and returned it verbatim - the original added_at, discarded_at still
# set, deduped true, exit zero - and created no live attachment. Their script
# counted exit codes and reported "attached 10 fresh" while creating nothing.
#
# The only repair was to make the bytes different. They re-rendered the images,
# and for one file whose pixels were already correct they did a lossless
# re-encode purely to change the hash. That is the cost of a silent no-op: work
# spent defeating the deduplication rather than fixing the data.
#
# The manual made it worse. "Re-adding identical bytes restores the object" is
# true of remove, which deletes the content, and not of discard, which sets a
# card-scoped stamp that beats it. The two sentences sit close together, so
# reading it as a general restore is the natural mistake rather than a careless
# one.
#
# Refusing rather than reviving. Reviving is the friendlier answer and discard
# is described as setting aside rather than deleting, so being unable to put it
# back is the surprise - but refusing is the one that cannot lose data, and an
# explicit revive can follow if the refusal turns out to be annoying. A write
# that cannot take must not report success either way.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-14T02:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Pictures', dir => $root, members => ['michael'],
    columns => ['backlog, done'],
    sow_prefix => 'PCS', epic_prefix => 'PCE', ticket_prefix => 'PCT',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Has pictures' );
my $other = $tira->create_record( project => $root, type => 'ticket', title => 'Also has pictures' );

sub live {
    my ($ref) = @_;
    return grep { !$_->{discarded_at} }
      @{ $tira->attachment_list( project => $root, ref => $ref ) };
}

my $bytes = "the screenshot that did not change\n";
my $added = $tira->attachment_add_content( project => $root, ref => $card->{ref},
    filename => 'part1-mobile.png', content => $bytes );
is( scalar( live( $card->{ref} ) ), 1, 'the attachment is on the card' );

$tira->attachment_discard( project => $root, ref => $card->{ref}, sha => $added->{sha} );
is( scalar( live( $card->{ref} ) ), 0, 'and discarding it takes it off' );

# --- the add that used to report success ---------------------------------------

my $refused = !eval {
    $tira->attachment_add_content( project => $root, ref => $card->{ref},
        filename => 'part1-mobile.png', content => $bytes );
    1;
};
ok( $refused, 'adding bytes that are discarded on this card is refused' );
like( $@, qr/discard/i, 'and the refusal says why, which is the part a script can act on' );
is( scalar( live( $card->{ref} ) ), 0,
    'with nothing created, which is what the old behaviour did while reporting otherwise' );

# --- the same bytes elsewhere are nobody else's business -------------------------
#
# The stamp is card-scoped. Refusing the bytes everywhere would make one card's
# decision reach across the board.

my $elsewhere = $tira->attachment_add_content( project => $root, ref => $other->{ref},
    filename => 'part1-mobile.png', content => $bytes );
is( $elsewhere->{sha}, $added->{sha}, 'the same bytes are the same object' );
is( scalar( live( $other->{ref} ) ), 1, 'and they attach to a card that never discarded them' );

# --- different bytes are unaffected ----------------------------------------------
#
# What they had to do by hand: re-render until the hash changed. It still works,
# and now it is a choice rather than the only way through.

my $rerendered = $tira->attachment_add_content( project => $root, ref => $card->{ref},
    filename => 'part1-mobile.png', content => "the screenshot after re-rendering\n" );
isnt( $rerendered->{sha}, $added->{sha}, 're-rendered bytes are a different object' );
is( scalar( live( $card->{ref} ) ), 1, 'and they attach to the card that discarded the old ones' );

# --- and adding twice over is still just deduplication -----------------------------
#
# The ordinary case must not become a refusal. Adding the same live attachment
# again has always been a no-op that says so, and that is honest because the
# attachment really is there.

my $again = $tira->attachment_add_content( project => $root, ref => $card->{ref},
    filename => 'part1-mobile.png', content => "the screenshot after re-rendering\n" );
ok( $again->{deduped}, 'adding a live attachment again still dedupes' );
is( scalar( live( $card->{ref} ) ), 1, 'and does not double it' );

# --- what the manual promises ------------------------------------------------------
#
# The sentence that sent them down this road. Remove deletes the content and
# re-adding really does restore it; discard does not work that way, and the
# manual has to say which is which where somebody reading one will see the other.

my $manual = do {
    open my $fh, '<:raw', 'SKILLS.md' or die $!;
    local $/;
    <$fh>;
};
my ($para) = grep { /Re-adding identical bytes/ } split /\n\n/, $manual;
ok( $para, 'the manual still explains what re-adding identical bytes does' );
like( $para, qr/discard/i,
    'and says how discard differs, beside the sentence that reads as a general restore' );

done_testing;

__END__

=head1 NAME

146-an-add-that-could-not-take.t - an add that cannot take is refused

=head1 DESCRIPTION

Adding bytes whose hash was discarded on a card deduped onto the discarded
record and returned it verbatim - C<deduped> true, C<discarded_at> still set,
exit zero - while creating no live attachment. A script counting exit codes
reported ten fresh attachments and had created none; ten screenshots were lost
and the only repair was to change the bytes.

The add is now refused, naming the discard. The stamp is card-scoped, so the
same bytes still attach to any other card, and genuinely different bytes still
attach here. Adding a live attachment again still dedupes, because that answer
is true.

=cut
