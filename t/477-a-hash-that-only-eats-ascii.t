#!/usr/bin/env perl
# TKT-687. A required-action or checklist proof over 2000 characters is
# stored as an attachment via attachment_add_content, which hashes it with
# sha256_hex. Digest::SHA dies with "Wide character in subroutine entry"
# when handed a character string containing code points above 255 - so a
# long proof containing an emoji, em dash, or accented character was
# refused, naming a hashing routine the caller has never heard of. A short
# proof never reaches the hash (it is stored inline), and a long ASCII
# proof hashes fine - only the combination of long-and-non-ASCII fails.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-01T15:00:00+0100' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Guarded', dir => $root, members => ['ada'],
    columns => ['backlog, doing'],
    sow_prefix => 'GHS', epic_prefix => 'GHE', ticket_prefix => 'GHT',
);
my $ticket = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'Some work' );

my $ascii_long    = ( 'a' x 2500 );
my $unicode_long  = ( 'a' x 2497 ) . "\x{2705}\x{2014}\x{00e9}";    # tick, em dash, e-acute
my $unicode_short = "quick \x{2705} note";

# --- the fix: a long proof with non-ASCII content is stored, not refused ----

my $long_non_ascii = eval {
    $tira->attachment_add_content(
        project => $root, ref => $ticket->{ref},
        filename => 'proof.txt', content => $unicode_long,
    );
};
ok( !$@, 'a long proof containing non-ASCII characters is stored rather than dying' ) or diag($@);
ok( $long_non_ascii && $long_non_ascii->{sha}, 'and it comes back with a real sha' );

# --- reads back byte-identical ----------------------------------------------

{
    use Encode qw(encode_utf8);
    my $got = $tira->attachment_get(
        project => $root, sha => $long_non_ascii->{sha}, extension => $long_non_ascii->{extension},
    );
    is( $got->{content}, encode_utf8($unicode_long),
        'the stored bytes are exactly the UTF-8 encoding of what was sent' );
}

# --- the same holds for a short non-ASCII proof (already worked, still works) ---

my $short_non_ascii = eval {
    $tira->attachment_add_content(
        project => $root, ref => $ticket->{ref},
        filename => 'proof.txt', content => $unicode_short,
    );
};
ok( !$@, 'a short proof containing non-ASCII characters still stores' ) or diag($@);

# --- an ASCII proof keeps the hash it has always had - nothing to migrate --

my $ascii_attachment = $tira->attachment_add_content(
    project => $root, ref => $ticket->{ref},
    filename => 'proof.txt', content => $ascii_long,
);
use Digest::SHA qw(sha256_hex);
is( $ascii_attachment->{sha}, sha256_hex($ascii_long),
    'a pure-ASCII proof keeps the exact hash it always had - no migration needed' );

# --- and the whole thing happens with no wide-character warning ------------

{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    $tira->attachment_add_content(
        project => $root, ref => $ticket->{ref},
        filename => 'proof.txt', content => $unicode_long . 'x',
    );
    ok( !( grep { /Wide character/ } @warnings ), 'no "Wide character" warning is produced' );
}

# --- and it composes with the real caller: a long non-ASCII --proof --------

my $item = $tira->required_item_add(
    project => $root, ref => $ticket->{ref}, item => 'Ship it', status => 'pending', author => 'ada',
);
my $marked = $tira->required_item_update(
    project => $root, ref => $ticket->{ref}, id => $item->{id}, status => 'done', author => 'ada',
    command => ['d2 tira.dashboard'], proof => [$unicode_long],
);
is( $marked->{status}, 'done', 'a required action with a long non-ASCII proof is marked done, not refused' );

done_testing;

__END__

=head1 NAME

t/477-a-hash-that-only-eats-ascii.t - a long proof containing non-ASCII
characters no longer dies inside a hashing routine the caller never asked
for

=head1 DESCRIPTION

C<attachment_add_content> hashed its content with C<sha256_hex> before
encoding it to bytes, and C<Digest::SHA> dies on a character string
containing code points above 255. A required-action or checklist proof over
2000 characters routes through this path, so a long proof quoting an emoji,
an em dash, or an accented name - all ordinary in captured terminal output -
was refused with a message naming an internal hashing routine rather than
anything about the proof itself.

C<attachment_add_content> now encodes character content to UTF-8 bytes
before hashing and writing, matching the C<_response_bytes> pattern already
used in C<DashboardWeb> and C<OnboardWeb>. An existing pure-ASCII attachment
keeps the exact hash it always had, since encoding a byte string is a
no-op. TKT-687.

=cut
