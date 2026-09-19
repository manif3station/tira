#!/usr/bin/env perl
# TKT-1059, self-caught during a 2-hourly improvement hunt while TKT-991 was
# mid-verify: t/lib/Suite.pm's own =head2 cli_source POD block still
# described cli_source as only "the command surface...concatenated" - no
# mention that TKT-973 (5.93) gave it an optional NAME argument returning
# just that one file's content, dying on 0 or 2+ matches. A reader
# consulting the file's own documentation would not learn the by-name form
# exists at all, even though =head2 view_source right below it documents
# its own identical by-name behavior.
#
# Documentation-only: no code behavior changes here, only the POD text.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use Test::More;

my $path = File::Spec->catfile( 't', 'lib', 'Suite.pm' );
open my $fh, '<', $path or die "Cannot read $path: $!";
local $/;
my $pod = <$fh>;
close $fh;

my ($cli_source_block) = $pod =~ /(=head2 cli_source.*?)(?==head2 |\z)/s;
ok( defined $cli_source_block, 'found the cli_source POD block to check' )
  or BAIL_OUT('nothing to check this against');

like( $cli_source_block, qr/NAME/,
    "cli_source's own POD mentions the NAME argument" );
like( $cli_source_block, qr/dies?\b.{0,40}(?:no match|more than one|match)/is,
    "and describes what happens on no match or more than one - the same failure shape view_source's POD already documents" );

done_testing();

__END__

=head1 NAME

1059-a-pod-that-forgot-its-own-argument.t - t/lib/Suite.pm's cli_source POD
documents its own NAME argument

=head1 DESCRIPTION

TKT-1059: C<cli_source>'s POD block in C<t/lib/Suite.pm> described only the
concatenated, whole-layer behavior, never mentioning the optional NAME
argument TKT-973 (5.93) gave it - a by-name lookup that dies on no match or
more than one, the same shape C<view_source>'s own POD (right below it in
the same file) already documents for itself. A reader consulting this
file's own documentation to learn what C<cli_source> does would not learn
the by-name form exists. Fixed by extending the POD block to describe it.

=cut
