#!/usr/bin/env perl
# tira.changes prints the entire changelog, every time, with no way to bound
# it - 5807 lines, 345KB - though the upgrade notice that tells an agent to
# run it already states both endpoints in one sentence: "Tira is now X -
# this board last heard Y". cli/changes has no option parsing at all; any
# argument, real or bogus, is silently accepted and does nothing. TKT-404.

use strict;
use warnings;

use File::Spec;
use Test::More;

my $root = File::Spec->rel2abs('.');
my $dispatcher = File::Spec->catfile( $root, 'cli', 'changes' );

sub run {
    my (@argv) = @_;
    my $said = qx(perl "$dispatcher" @argv 2>&1);
    return ( $? >> 8, $said );
}

open my $fh, '<:raw', File::Spec->catfile( $root, 'Changes' ) or die $!;
my $full = do { local $/; <$fh> };
close $fh;

# --- no flag is unchanged, byte for byte -------------------------------------

{
    my ( $status, $said ) = run();
    is( $status, 0, 'the unbounded read still exits 0' );
    is( $said, $full, 'and is byte-identical to the file itself, as before' );
}

# --- --since bounds by content, not merely by a shorter byte count ----------
#
# A truncation bug (say, cutting the last N bytes) would also produce fewer
# bytes than the full read - so this checks for the SPECIFIC entries that
# should and should not survive, not just that the output got shorter.

{
    my ( $status, $said ) = run( '--since', '3.60' );
    is( $status, 0, 'a real, older version bounds cleanly' );
    like( $said, qr/^3\.69\s/m, 'and a recent entry (3.69) survives the bound' );
    unlike( $said, qr/^3\.60\s/m, '--since is exclusive: the named version itself does not appear' );
    unlike( $said, qr/^2\.09\s/m, 'and nothing from long before the bound appears' );
    cmp_ok( length($said), '<', length($full), 'and the bounded output is genuinely shorter' );
}

# --- an unknown version is refused, not silently ignored --------------------

{
    my ( $status, $said ) = run( '--since', '99.99' );
    isnt( $status, 0, 'a version this changelog never had is refused' );
    like( $said, qr/99\.99/, 'naming what was asked for' );
}

# --- a malformed version is refused, not silently ignored -------------------

{
    my ( $status, $said ) = run( '--since', 'not-a-version' );
    isnt( $status, 0, 'a malformed version is refused' );
    like( $said, qr/version/i, 'saying so' );
}

done_testing;

__END__

=head1 NAME

360-a-changelog-that-can-be-bounded.t - tira.changes takes --since VERSION

=head1 DESCRIPTION

C<tira.changes> printed the entire 345KB changelog every time, with no way
to bound it, though the upgrade notice that tells an agent to run it
already states both endpoints - the board's last-heard version and the
current one - in one sentence. This proves the unbounded read is
byte-identical to before, C<--since VERSION> prints only genuinely newer
entries (checked by content, not merely a shorter byte count), and an
unknown or malformed version is refused rather than silently accepted.

=cut
