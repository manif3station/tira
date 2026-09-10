#!/usr/bin/env perl
# Suite::cli_source takes a module name and ignores it.
#
# TKT-973. Ten call sites across the suite pass cli_source('CLI.pm'),
# cli_source('Police.pm'), and the like, expecting the same thing
# view_source(NAME) already gives: that ONE file's source, not the whole
# lib/Tira/CLI layer concatenated. cli_source() has always ignored its
# argument and returned the whole layer regardless - a false green on
# TKT-829, whose assertion checked lib/Tira/CLI/Serve.pm's content while
# actually reading lib/Tira/CLI.pm's too, and the broader text happened to
# satisfy it anyway.
#
# HONOUR IT, not refuse it: view_source's own shape (find the named file
# under the walked path, die if it is not there or is ambiguous, return
# just its content) is what every one of the ten callers already believes
# cli_source does. The no-argument whole-layer form stays, since t/566
# composes it with engine_source deliberately to search both layers as one
# text.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 't/lib';
use Suite;

# --- naming a real file returns THAT file, not the whole layer -------------

{
    my $named = Suite::cli_source('Police.pm');
    my $whole  = Suite::cli_source();

    ok( length($named) > 0, 'naming a real file under lib/Tira/CLI returns something' );
    cmp_ok( length($named), '<', length($whole),
        'and it is narrower than the whole layer - the bug returned the same length either way' );

    # t/486 marker: about this file, not its code - checking cli_source's
    # NAMED-file output against the real file's own content by hand, not
    # asserting anything about what Police.pm's code does.
    open my $fh, '<:raw', 'lib/Tira/CLI/Police.pm' or die $!;
    local $/;
    my $real = <$fh>;
    is( $named, $real, 'and it is exactly that file, not a superset or a subset of it' );
}

# --- a name one path segment deep works the same way ------------------------

{
    my $named = Suite::cli_source('Job/Feeder.pm');
    # t/486 marker: about this file, not its code - same as above.
    open my $fh, '<:raw', 'lib/Tira/CLI/Job/Feeder.pm' or die $!;
    local $/;
    my $real = <$fh>;
    is( $named, $real, 'a nested name resolves to the nested file, not a basename collision' );
}

# --- a name not under lib/Tira/CLI is an error, not a silent whole-layer answer --

{
    my $refused = !eval { Suite::cli_source('NoSuchModule.pm'); 1 };
    ok( $refused, 'a name that matches nothing under lib/Tira/CLI dies rather than silently answering the whole layer' )
      or diag('cli_source(NoSuchModule.pm) returned instead of dying - the bug this card is about');
    like( $@, qr/no CLI module named/i, 'and says so, naming what was not found' )
      if $refused;
}

# --- a name matching more than one file is refused, not answered by the first --
#
# The real lib/Tira/CLI tree has no two files sharing a path suffix today, so
# this exercises the matcher Suite::_named_module directly against a
# synthetic list rather than fabricating files on disk.

{
    my $refused = !eval {
        Suite::_named_module( [ 'lib/Tira/CLI/Job/A.pm', 'lib/Tira/CLI/Other/A.pm' ], 'A.pm' );
        1;
    };
    ok( $refused, 'a name matching more than one file dies rather than silently picking the first' )
      or diag('_named_module returned instead of dying on an ambiguous match');
    like( $@, qr/more than one/i, 'and says so, rather than a generic error' )
      if $refused;
}

# --- the single-string contract holds in list context too -------------------

{
    my @lines = Suite::cli_source('Police.pm');
    is( scalar @lines, 1, 'cli_source(NAME) returns one scalar even asked for in list context - not the file split into lines' );
}

# --- the no-argument whole-layer form is unaffected --------------------------

{
    my $whole = Suite::cli_source();
    like( $whole, qr/\S/, 'the whole-layer form still answers with something' );
    like( $whole, qr/package Tira::CLI::Police/, 'and it still includes every file, Police.pm among them' );
    like( $whole, qr/package Tira::CLI::Job::Feeder/, 'and Job::Feeder.pm too' );
}

done_testing();

__END__

=head1 NAME

973-a-name-nobody-read.t - Suite::cli_source(NAME) now reads NAME, not the whole layer

=head1 WHY

TKT-973. Ten call sites named a file and were handed the whole lib/Tira/CLI
layer concatenated, which cost a false green on TKT-829 - an assertion
meant to check one file's content passed because a DIFFERENT file in the
same concatenation happened to satisfy it too.

=head1 WHAT IS ASSERTED

That a named file resolves to exactly that file's own content; that a
nested path (one directory deep) resolves the same way; that an unmatched
name dies rather than silently answering the whole layer; that a name
matching more than one file dies rather than silently picking the first
(exercised against a synthetic list via C<_named_module>, since the real
lib/Tira/CLI tree has no natural collision); that the returned content is
a single scalar even in list context; and that the no-argument whole-layer
form used by t/566 is unaffected.

=cut
