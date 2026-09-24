#!/usr/bin/env perl
# TKT-722. Every --set-* array option (record.update's key-details,
# deliverables, acceptance, test-steps, bdd, atdd, labels, affects-versions,
# scope-in, scope-out) takes a PATH to a JSON file, not inline text - but
# nothing says so before the natural first attempt fails. Worse, a caller
# who mistakenly passes a large inline JSON/text string directly (as if it
# were the append form's text argument) gets that ENTIRE string echoed back
# verbatim in the refusal, via _json_array_input's own file-not-readable
# path - reproduced at ~1,900 characters, and it cost a real junk card
# (TKT-719) when the error was discarded through a grep pipe and the
# caller never saw it.
#
# WRITTEN RED: _json_array_input still tries to open() any argument as a
# file, including one containing a newline or a brace, and echoes it back
# in full when that open() fails.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-24T16:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'A path mistaken for its own content', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'PMS', epic_prefix => 'PME', ticket_prefix => 'PMT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Contended' );

sub run_cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => 'record.update', type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

# --- THE BUG: a large inline JSON array, mistaken for a file path --------

my $inline_json = '[' . join( ',', map { qq("item $_ of a long inline array that was never meant to be a filename") } 1 .. 40 ) . ']';
ok( length($inline_json) > 1000, 'the inline argument really is over a thousand characters, matching the reported repro' );

my ( $status, $out, $err ) = run_cli(
    '--ref', $card->{ref}, '--author', 'claude', '--set-scope-in', $inline_json, '-o', 'json' );

isnt( $status, 0, 'a large inline JSON string in place of a file path is refused' );
like( $err, qr/--set-scope-in/, 'the refusal names the option' );
like( $err, qr/(?:PATH|path)/, 'and says a path was expected' );
ok( length($err) < 500, 'the refusal is short - it does not echo the whole 1000+ character argument back' )
  or diag("refusal was " . length($err) . " characters: $err");
unlike( $err, qr/item 40 of a long inline array/, 'the tail of the inline content does not appear - only a short preview, not the whole thing' );

# --- a newline-containing inline argument is refused the same way --------

my $inline_text = "line one\nline two\nline three";
( $status, $out, $err ) = run_cli(
    '--ref', $card->{ref}, '--author', 'claude', '--set-scope-in', $inline_text, '-o', 'json' );
isnt( $status, 0, 'a multi-line inline argument is refused the same way' );
like( $err, qr/--set-scope-in/, 'naming the option' );
ok( length($err) < 500, 'still short' );

# --- a brace-containing inline argument (a JSON object) is refused too ---

my $inline_object = '{"not": "an array, and not a path either"}';
( $status, $out, $err ) = run_cli(
    '--ref', $card->{ref}, '--author', 'claude', '--set-scope-in', $inline_object, '-o', 'json' );
isnt( $status, 0, 'a brace-containing inline argument is refused' );
like( $err, qr/--set-scope-in/, 'naming the option' );
like( $err, qr/(?:PATH|path)/, 'and says a path was expected' );

# --- a quote-containing inline argument is refused too --------------------

my $inline_quoted = 'this "looks like" quoted text, not a path';
( $status, $out, $err ) = run_cli(
    '--ref', $card->{ref}, '--author', 'claude', '--set-scope-in', $inline_quoted, '-o', 'json' );
isnt( $status, 0, 'a quote-containing inline argument is refused' );
like( $err, qr/--set-scope-in/, 'naming the option' );

# --- the same detection applies across the shared decode boundary, not ----
# --- just --set-scope-in - confirmed on two more of the ten options -------

for my $flag (qw(set-key-details set-acceptance)) {
    ( $status, $out, $err ) = run_cli(
        '--ref', $card->{ref}, '--author', 'claude', "--$flag", $inline_json, '-o', 'json' );
    isnt( $status, 0, "an inline JSON array is refused on --$flag too" );
    like( $err, qr/--\Q$flag\E/, "naming --$flag specifically, not a different option" );
    ok( length($err) < 500, "and stays short for --$flag" );
}

# --- an ordinary, merely-nonexistent file path is unaffected --------------

my $missing_path = File::Spec->catfile( $tmp, 'does-not-exist.json' );
( $status, $out, $err ) = run_cli(
    '--ref', $card->{ref}, '--author', 'claude', '--set-scope-in', $missing_path, '-o', 'json' );
isnt( $status, 0, 'a genuinely missing file is still refused' );
like( $err, qr/--set-scope-in/, 'naming the option, same as before' );
like( $err, qr/\Q$missing_path\E/, 'and still names the actual path that could not be read - unaffected by this fix' );

# --- the working case is unchanged -----------------------------------------

my $valid = File::Spec->catfile( $tmp, 'valid.json' );
open my $fh, '>', $valid or die $!;
print {$fh} '["first item", "second item"]';
close $fh;

( $status, $out, $err ) = run_cli(
    '--ref', $card->{ref}, '--author', 'claude', '--set-scope-in', $valid, '-o', 'json' );
is( $status, 0, 'a real JSON file path still succeeds' );
is( $err, '', 'with nothing on STDERR' );

done_testing();

__END__

=head1 NAME

722-a-path-mistaken-for-its-own-content.t - a --set-* array option given
an implausible file-path argument is refused with a short message, not
that argument echoed back in full

=head1 DESCRIPTION

TKT-722. C<_json_array_input> (the shared boundary for all ten C<--set-*>
array options) used to try C<open()> on any argument, including a large
inline JSON array or object, or a multi-line string, a caller mistakenly
typed inline. The resulting C<open()> failure echoed that entire
argument back into the refusal, reproduced at roughly 1,900 characters,
which cost a real junk card (TKT-719) when the refusal was accidentally
discarded through a grep pipe and never seen. An argument containing a
newline, brace, bracket, or quote is now treated as inline content
rather than a path, refused with a short, truncated message naming the
option before C<open()> is ever attempted - a deliberate tradeoff rather
than a claim that no real path can contain these characters (Unix
permits all four in a genuine filename), and a merely long ordinary path
is not singled out by length alone. A genuinely missing or unreadable
ordinary path is unaffected and still names the real path in its own
refusal.

=cut
