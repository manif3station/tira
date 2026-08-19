#!/usr/bin/env perl
# Naming a board explicitly is honoured from most directories and silently
# overridden from any directory that itself sits inside another Tira project -
# with no warning and no difference in the output the caller sees. Measured
# live: an identical alias, naming a scratch board, resolved to the real board
# instead from two working directories, and a real command run from one of
# them landed on the wrong board - a column was unwatched and a stray card was
# created there, found only because police reported it. TKT-368.

use strict;
use warnings;

use Cwd qw(realpath);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
$tmp =~ /\A([^\x00-\x1f\x7f]+)\z/ or die 'Unsafe temporary path';
$tmp = $1;

my $named_dir = File::Spec->catdir( $tmp, 'named-board' );
my $cwd_dir   = File::Spec->catdir( $tmp, 'cwd-board' );
my $elsewhere = File::Spec->catdir( $tmp, 'elsewhere' );
require File::Path;
File::Path::make_path($elsewhere);

my $tira = Tira->new;
$tira->create_project( dir => $named_dir, name => 'Named' );
$tira->create_project( dir => $cwd_dir,   name => 'Cwd' );

my $resolver = Tira->new( path_resolver => sub {
    my ($name) = @_;
    return $named_dir if $name eq 'named-alias';
    die "unknown alias";
} );

is( $resolver->discover_project( project => 'named-alias', start => $elsewhere ),
    realpath($named_dir),
    'the named board is used when the working directory is not itself a board' );

eval {
    $resolver->discover_project( project => 'named-alias', start => $cwd_dir );
};
like( $@, qr/\Q$named_dir\E/, 'refusing names the board that was asked for' );
like( $@, qr/\Q$cwd_dir\E/,   'and the board the working directory would have found instead' );
unlike( $@, qr/named-alias/,
    'the message gives paths to compare, not the alias name a reader cannot resolve themselves' );

my $nested_in_cwd_board = File::Spec->catdir( $cwd_dir, 'src', 'deeper' );
File::Path::make_path($nested_in_cwd_board);
eval {
    $resolver->discover_project( project => 'named-alias', start => $nested_in_cwd_board );
};
like( $@, qr/\Q$cwd_dir\E/,
    'the disagreement is caught even from a directory nested inside the other board, not only its root' );

my $same_alias = Tira->new( path_resolver => sub { return $named_dir } );
is( $same_alias->discover_project( project => 'anything', start => $named_dir ),
    realpath($named_dir),
    'no refusal when the named board and the working directory agree' );

is( $tira->discover_project( start => $cwd_dir ), realpath($cwd_dir),
    'plain discovery with no project selector is unaffected - only an explicit selector triggers the check' );

done_testing;

__END__

=head1 NAME

295-a-name-the-working-directory-overruled.t - an explicit board selector beats
the working directory, or refuses rather than silently picking one

=head1 DESCRIPTION

discover_project resolves a project selector through an injected path
resolver this project does not own, and that resolver was measured returning
a different answer for the identical alias depending only on the working
directory - the real board instead of the named scratch one, from inside the
tree holding the real board. The failure was invisible: the command
succeeded, printed a normal record, and only a different reference prefix
made it detectable at all.

Unable to make the resolver itself ignore the working directory, this checks
its answer against what the working directory would have found on its own
and refuses, naming both, rather than trusting either guess when they
disagree.

=cut
