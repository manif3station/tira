#!/usr/bin/env perl

use strict;
use warnings;

use File::Find ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;
use Tira::CLI::Usage;

# TKT-1004. Tira::CLI::Usage::_edit_distance (TKT-298) and Tira::_edit_distance
# (TKT-635, added the same day) are byte-for-byte identical Levenshtein
# implementations, one private to each module, each backing its own
# "did you mean" suggestion. A future fix to the algorithm applied to one
# would silently leave the other on the old behavior.

# Walk the whole of lib/ - not engine_source()/cli_source() separately, since
# the point of this test is to compare the two halves against each other, and
# a helper that already excludes one side would make the comparison one-sided
# by construction.
my @modules;
File::Find::find(
    { no_chdir => 1, wanted => sub {
          push @modules, $File::Find::name if /\.pm\z/;
      } },
    'lib' );
cmp_ok( scalar @modules, '>=', 4, 'lib/ was walked - ' . scalar(@modules) . ' modules' );

my $count = 0;
for my $module (@modules) {
    open my $fh, '<:raw', $module or die "$module: $!";
    local $/;
    my $source = <$fh>;
    $count += () = $source =~ /^sub _edit_distance\b/mg;
}
is( $count, 1, 'exactly one sub _edit_distance exists anywhere under lib/' );

# The behavior itself must survive the dedup exactly as it is today: both the
# CLI's unknown-option suggestion and the engine's near-miss argument
# suggestion depend on this function agreeing with itself between the two
# call sites, which is trivially true while there is only one definition.
is( Tira::_edit_distance( 'colum', 'column' ), 1,
    q{the shared implementation the CLI now calls into still measures a one-letter drop} );

done_testing;

__END__

=head1 NAME

1004-a-second-copy-of-the-same-ten-lines.t - one Levenshtein, not two

=head1 DESCRIPTION

Tira::CLI::Usage::_edit_distance and Tira::_edit_distance were introduced on
the same day (TKT-298, TKT-635) as byte-for-byte identical implementations of
the same algorithm, each private to its own module. A fix to one would not
reach the other unless someone remembered both exist. This test counts every
C<sub _edit_distance> definition under C<lib/> and fails while there are two.

=cut
