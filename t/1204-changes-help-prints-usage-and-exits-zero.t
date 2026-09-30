#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use Test::More;

# TKT-1204. Sweeping `--help` across every command in docs/commands.md, all but
# tira.changes printed a Usage line and exited 0 (policies and skills print their
# own documents). `d2 tira.changes --help` printed "Unknown option: help", then
# the usage, and exited 255, because cli/changes parses only --since and treats
# --help as one more unknown option.
#
# What is held here: --help prints the usage and exits 0 without calling itself
# an unknown option; a genuinely unknown option still fails with the usage; and
# the plain and --since forms are untouched.

my $root       = File::Spec->rel2abs('.');
my $dispatcher = File::Spec->catfile( $root, 'cli', 'changes' );

sub run {
    my (@argv) = @_;
    my $said = qx(perl "$dispatcher" @argv 2>&1);
    return ( $? >> 8, $said );
}

{
    my ( $status, $said ) = run('--help');
    is( $status, 0, '--help exits 0' );

    # non-empty is the whole claim for this one: the assertions after it look
    # for words, and would pass vacuously against a command that said nothing.
    like( $said, qr/\S/, '--help says something' );

    like( $said, qr/Usage: d2 tira\.changes \[--since VERSION\]/, '--help prints the usage line' );
    unlike( $said, qr/Unknown option/, '--help does not call itself an unknown option' );
}

{
    my ( $status, $said ) = run('--bogus');
    isnt( $status, 0, 'a genuinely unknown option still fails' );
    like( $said, qr/Usage: d2 tira\.changes/, 'and still prints the usage' );
}

{
    my ( $status, $said ) = run( '--since', '5.242' );
    is( $status, 0, '--since VERSION still exits 0' );
    like( $said, qr/^5\.246 /m, 'and still prints the newer entries' );
    unlike( $said, qr/^5\.242 /m, 'and stops before the version it was given' );
}

{
    my ( $status, $said ) = run();
    is( $status, 0, 'with no option the changelog still prints' );
    like( $said, qr/^Revision history for Tira/, 'and starts with the changelog title' );
}

done_testing;

__END__

=head1 NAME

1204-changes-help-prints-usage-and-exits-zero.t - tira.changes --help is help, not an unknown option

=head1 DESCRIPTION

TKT-1204. C<d2 tira.changes --help> exited 255 with C<Unknown option: help>
where every other command prints its usage and exits 0. This file holds that
C<--help> prints the usage line and exits 0, that a bogus option still fails
with the usage, and that the bare command still prints the changelog.

=cut
