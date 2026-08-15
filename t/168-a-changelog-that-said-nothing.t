#!/usr/bin/env perl
# A project can tell "nothing changed" from "I could not read it".
#
# He asked why d2 tira.changes returns 0 bytes. zen-framework reported the same
# thing independently, minutes apart, and measured it properly:
#
#     from their project directory : 0 bytes, exit 0, nothing on stderr
#     from /tmp                    : 164,773 bytes
#     tira.skills, tira.usage, tira.policies from the same directory : all fine
#
# It is not reproducible here - it prints the whole changelog from a fresh Tira
# project, from this skill's own directory, from /tmp, in every output format -
# and their files are not mine to look at. So what is fixed here is not the
# cause but the silence: whichever copy of the skill resolved for them, the
# command exited 0 having printed nothing.
#
# Their framing is the right one and it is this project's oldest lesson: an
# instrument quiet because it is broken looks exactly like one quiet because
# there is nothing to say. A script cannot tell those apart, and one of theirs
# reads this command hourly to record which version it audited against.
#
# It matters more than its size because of what the command is for. His message
# to them was "Tira has been updated. Review the new changes d2 tira.changes" -
# so the one command that tells a project their bug was fixed answered with
# silence, which reads as nothing having changed since they reported it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Run qw(run_split);
use Shipped qw(runnable_ok);
use Tira::CLI;

my $entrypoint = File::Spec->rel2abs( File::Spec->catfile(qw(cli changes)) );
runnable_ok( $entrypoint, 'the changelog command ships and is runnable' );

sub run_from {
    my ($root) = @_;
    return run_split( $^X, File::Spec->catfile( $root, 'cli', 'changes' ) );
}

sub skill_at {
    my ( $root, $changelog ) = @_;
    mkdir $root;
    mkdir File::Spec->catdir( $root, 'cli' );
    open my $copy, '<:raw', $entrypoint or die $!;
    my $source = do { local $/; <$copy> };
    close $copy;
    my $there = File::Spec->catfile( $root, 'cli', 'changes' );
    open my $out, '>:raw', $there or die $!;
    print {$out} $source;
    close $out;
    chmod 0755, $there or die $!;
    if ( defined $changelog ) {
        open my $log, '>:raw', File::Spec->catfile( $root, 'Changes' ) or die $!;
        print {$log} $changelog;
        close $log;
    }
    return $root;
}

my $tmp = tempdir( CLEANUP => 1 );

# --- a changelog that is there ------------------------------------------------------
#
# Unchanged, byte for byte. Whatever is done about the silence must not touch
# the answer, because a project diffing this against its own capture would see
# every line move.

{
    my $real = "Revision history for Tira\n\n1.75  2026-08-14\n    - something happened.\n";
    my $root = skill_at( File::Spec->catdir( $tmp, 'good' ), $real );
    my ( $status, $out, $err ) = run_from($root);
    is( $status, 0, 'a real changelog is printed and the command succeeds' );
    # Line endings normalised, and nothing else. What this asserts is that
    # the command adds nothing of its own - no header, no footer, no blank
    # line - so a project diffing this against its own capture sees nothing
    # move. On Windows the command's own STDOUT is a text handle and every
    # newline comes back as CRLF, which is the platform behaving normally and
    # not the command adding anything. Comparing the bytes made this fail
    # there for a difference the assertion is not about. TKT-222.
    ( my $printed = $out ) =~ s/\r\n/\n/g;
    is( $printed, $real, 'byte for byte, with nothing added' );
    is( $err, '', 'and nothing said on the way' );
}

# --- a changelog that is empty --------------------------------------------------------
#
# What they measured: zero bytes and success. This is the whole card.

{
    my $root = skill_at( File::Spec->catdir( $tmp, 'empty' ), '' );
    my ( $status, $out, $err ) = run_from($root);
    isnt( $status, 0, 'an empty changelog is a failure rather than an empty answer' );
    is( $out, '', 'nothing is printed, because there was nothing to print' );
    like( $err, qr/empty/i, 'and it says the changelog is empty' );
    like( $err, qr/Changes/, 'naming the file it read, so the next report says which copy resolved' );
}

# --- a changelog that is not there ------------------------------------------------------
#
# This path already worked and must keep working: a missing file is a different
# fault from an empty one and has always been loud.

{
    my $root = skill_at( File::Spec->catdir( $tmp, 'missing' ), undef );
    my ( $status, $out, $err ) = run_from($root);
    isnt( $status, 0, 'a missing changelog is still a failure' );
    like( $err, qr/Cannot read/, 'and still says it could not read it' );
    like( $err, qr/Changes/, 'naming the file' );
}

# --- a changelog of nothing but whitespace ------------------------------------------------
#
# A file caught mid-write can be a newline. Bytes are not the question; whether
# there is anything to read is.

{
    my $root = skill_at( File::Spec->catdir( $tmp, 'blank' ), "\n\n   \n" );
    my ( $status, undef, $err ) = run_from($root);
    isnt( $status, 0, 'a changelog of nothing but blank lines is a failure too' );
    like( $err, qr/empty/i, 'and says so' );
}

done_testing;

__END__

=head1 NAME

168-a-changelog-that-said-nothing.t - nothing changed is told apart from could not read

=head1 DESCRIPTION

C<tira.changes> exited 0 having printed nothing, so a project could not tell
"nothing has changed" from "I could not read it" - reported by the owner and,
independently and more precisely, by a project whose hourly audit reads the
command to record which version it ran against.

The cause was not reproducible here and their files are not mine to inspect, so
what is fixed is the silence: an empty or blank changelog now fails and names
the file it read, which is what tells the next reporter which copy resolved. A
real changelog is printed byte for byte as before.

=cut
