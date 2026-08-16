#!/usr/bin/env perl
# The suite reaches a board the way real usage reaches one.
#
# A board is referred to without naming where it sits, so the agent working a
# project cannot go round the CLI and edit the files. That reference is resolved
# for the caller. It is the route every real invocation takes.
#
# The suite took the other route almost everywhere: 179 of 207 files handed a
# command a path outright, twenty set the environment and every one of those set
# it to a path as well. So the resolving route was exercised nowhere, and when
# 2.00 moved the dashboard application into workers that could not resolve
# anything, the suite stayed green at 100% coverage, ten browser tests passed
# against a live page, and the owner found it by opening a browser.
#
# This is a floor, not a ratio. Nobody decided the suite would reach boards one
# way; it drifted there, and nothing said so.

use strict;
use warnings;

use File::Spec;
use Test::More;

use lib 't/lib';
use Suite qw(assertion_files);

my @tests = assertion_files();
cmp_ok( scalar @tests, '>', 100, 'there is a suite to measure' );

my ( $by_reference, $by_environment ) = ( 0, 0 );
for my $file (@tests) {
    open my $fh, '<', $file or die "Cannot read $file: $!";
    my $body = do { local $/; <$fh> };
    close $fh;

    $by_environment++ if $body =~ /TIRA_HOME/;
    $by_reference++   if $body =~ /path_resolver/;
}

# The environment route, which is how a board is selected without an argument.
cmp_ok( $by_environment, '>=', 15,
    'the suite selects a board through the environment in more than a handful of places' );

# And the resolving route, which is the one that was broken while everything
# was green. One file is not coverage; it is a reminder that this can drift
# back to none.
cmp_ok( $by_reference, '>=', 3,
    'and reaches one through a resolver, which is what real usage always does' );

done_testing;

__END__

=head1 NAME

213-how-the-suite-reaches-a-board.t - a floor under the route real usage takes

=head1 DESCRIPTION

179 of 207 test files handed a command a board path outright; twenty used the
environment and every one of those gave it a path too. The route real usage
takes - a reference somebody has to resolve - was exercised nowhere, and a
change that broke it left the suite green.

A floor rather than a ratio: nobody chose the drift, and nothing reported it.

=cut
