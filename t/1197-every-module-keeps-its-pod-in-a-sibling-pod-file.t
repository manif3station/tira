#!/usr/bin/env perl

use strict;
use warnings;

use File::Find;
use Test::More;

# TKT-1197. Some modules under lib/ still carry their documentation inline, so
# the .pm file is part code and part prose and its line count says little about
# the code. The rest keep their POD in a sibling .pod file. The rule is walked
# from lib/ rather than naming files, so a module added later is held to it too.

my @modules;
find( sub { push @modules, $File::Find::name if /\.pm\z/ }, 'lib' );
@modules = sort @modules;
cmp_ok( scalar @modules, '>', 0, 'the walk found modules under lib/' );

my @inline;
for my $path (@modules) {
    open my $in, '<', $path or die "Cannot read $path: $!";
    while ( my $line = <$in> ) {
        if ( $line =~ /\A=(?:head[1-4]|pod|over|item|back|begin|end|for|encoding|cut)\b/ ) {
            push @inline, $path;
            last;
        }
    }
    close $in;
}

is_deeply( \@inline, [], 'no module carries inline POD; each keeps it in a sibling .pod file' )
  or diag( "Inline POD found in:\n" . join( '', map { "  $_\n" } @inline ) );

for my $path (@modules) {
    ( my $pod = $path ) =~ s/\.pm\z/.pod/;
    next if grep { $_ eq $path } @inline;
    ok( -e $pod, "$path has its documentation in $pod" );
}

done_testing;

__END__

=head1 NAME

1197-every-module-keeps-its-pod-in-a-sibling-pod-file.t - lib/ modules hold code, their POD lives beside them

=head1 DESCRIPTION

TKT-1197. Walks every C<.pm> under C<lib/> and fails for any that still has a POD
directive at the start of a line anywhere in the file, before or after C<__END__>,
naming each one. Modules that
pass must have a sibling C<.pod>. Nothing is named in the test, so a new module
is held to the same rule.

The check is line-based, like the POD tooling the rest of the suite uses: a
line inside a heredoc or a multi-line string that begins with one of these
directives is counted as POD too. No module has one, and if one ever does the
failure names the module and the fix is to indent or rebuild the string, not to
loosen this file.

=cut
