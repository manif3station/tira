#!/usr/bin/env perl

# TKT-709. attachment_list's plain form (--ref alone, no other flags)
# returned a bare array of raw stored references - no filename, no size,
# no content_type, no count/total_size envelope. --meta-only gave all of
# that. The flag whose name promises LESS (meta *only*) was the one that
# gave MORE, so an agent asking "what is on this card, and can I read it"
# ran the plain form and learned nothing useful.
#
# Michael's answer (Q-159): make the default listing the useful one -
# return the richer shape by default; --meta-only becomes a narrower or
# vestigial flag.
#
# Resolved as VESTIGIAL rather than narrower: --meta-only is relied on,
# unchanged, by an existing internal caller (Tira::CLI's own
# _stamp_attachment_types, which reads content_type FROM a meta_only
# call) and by several pre-existing tests that assert --meta-only
# includes content_type. Narrowing --meta-only to exclude content_type
# would break real, load-bearing behavior for no benefit once the
# default already includes everything --meta-only does. So --meta-only
# keeps doing exactly what it always did; the plain call now matches it.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

use lib 'lib';
use Tira;

my $tick = '2026-09-14T09:00:00Z';
my $tira = Tira->new( clock => sub { $tick } );
my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->create_project( name => 'The plain command was the wrong one', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'First' );
$tira->attachment_add_content(
    project => $root, ref => $card->{ref}, filename => 'evidence.txt', content => "EVIDENCE BYTES\n" );

# --- the plain call now gives the same shape --meta-only always gave -------

my $plain = $tira->attachment_list( project => $root, ref => $card->{ref} );
my $meta = $tira->attachment_list( project => $root, ref => $card->{ref}, meta_only => 1 );

is( ref $plain, 'HASH', 'the plain call now returns an envelope, not a bare array' );
is_deeply( $plain, $meta, 'the plain call and --meta-only agree exactly - meta_only is vestigial, not a second shape' );

is( $plain->{count}, 1, 'the envelope carries a count' );
is( $plain->{total_size}, length("EVIDENCE BYTES\n"), 'and a total_size' );
my $entry = $plain->{attachments}[0];
is( $entry->{filename}, 'evidence.txt', 'the entry has a computed filename' );
is( $entry->{size}, length("EVIDENCE BYTES\n"), 'and a real byte size' );
is( $entry->{content_type}, 'text/plain; charset=UTF-8', 'and a content_type - the field the old plain form never gave' );

# --- --since and --fields narrow ROWS/KEYS, they do not change the shape ---

my $since_only = $tira->attachment_list(
    project => $root, ref => $card->{ref}, since => '2026-09-14T10:00:00Z' );
is( ref $since_only, 'HASH', '--since alone still returns the envelope shape' );
is( $since_only->{count}, 0, 'and filters rows the same way it always did' );

my $fielded = $tira->attachment_list( project => $root, ref => $card->{ref}, fields => ['filename'] );
is( ref $fielded, 'ARRAY', '--fields keeps its own documented shape - an explicit field projection, not the envelope' );
is_deeply( [ sort keys %{ $fielded->[0] } ], [qw(filename sha)], '--fields still narrows to the sha plus the named field' );

# --- --meta-only genuinely changes nothing now - it is accepted, not read --

my $meta_again = $tira->attachment_list( project => $root, ref => $card->{ref}, meta_only => 0 );
is_deeply( $meta_again, $plain, 'meta_only => 0 gives the identical result to meta_only => 1 or omitted entirely' );

done_testing;

__END__

=head1 NAME

1096-the-plain-command-was-the-wrong-one.t - attachment_list's plain form matches --meta-only

=head1 DESCRIPTION

TKT-709. C<attachment_list>'s plain form used to return a bare array of
raw stored references while C<--meta-only> returned filename, size,
content_type and a count/total_size envelope - the flag named for LESS
gave MORE. The plain form now matches C<--meta-only> exactly;
C<--meta-only> is accepted but no longer changes anything, since an
existing internal caller and several existing tests already rely on its
richer shape unchanged. C<--since>/C<--fields> continue to only narrow
rows or project fields, never the base shape.

=cut
