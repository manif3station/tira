#!/usr/bin/env perl
# --set-* array options refuse a bad file by quoting the JSON decoder's own
# internal state and an internal file and line number, rather than naming
# the option or what the file must contain.
#
# Measured 2026-08-29: --set-scope-in handed a plain-text file returned
#
#   error: "'true' expected, at character offset 0 (before \"tira.police.outstand...\")
#   at /home/.../lib/Tira.pm line 11809."
#
# Three faults, separable: it names no option, so a multi-update command
# cannot say which argument failed; it quotes the decoder's own expectation
# ('true' is a JSON literal the caller never wrote - just what the parser
# tried first); and it exposes an internal file and line number that moves
# every release and means nothing to the caller.
#
# All ten --set-* array options (record.update's key-details, deliverables,
# acceptance, test-steps, bdd, atdd, labels, affects-versions, scope-in,
# scope-out) share the same decode boundary, so this is one fix rather than
# ten.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-09T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'A decoder that named itself', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'DNS', epic_prefix => 'DNE', ticket_prefix => 'DNT',
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

my $plain_text = File::Spec->catfile( $tmp, 'plain.txt' );
open my $fh, '>', $plain_text or die $!;
print {$fh} "tira.police.outstanding is not a JSON array\n";
close $fh;

# --- the plain-text case ------------------------------------------------------

my ( $status, $out, $err ) = run_cli(
    '--ref', $card->{ref}, '--author', 'claude', '--set-scope-in', $plain_text, '-o', 'json' );

isnt( $status, 0, 'a plain-text file is still refused' );
like( $err, qr/--set-scope-in/, 'the refusal names the option that was given the bad file' );
like( $err, qr/JSON array/i, 'and says what the file must contain' );
like( $err, qr/\[\\?"[^"\\]+\\?",\s*\\?"[^"\\]+\\?"\]/, 'with an example of the shape' );
like( $err, qr/--scope-in/, 'and points at the repeated single-item form as the append alternative' );
unlike( $err, qr/lib\/Tira\.pm/, 'without exposing the internal file' );
unlike( $err, qr/line \d+/, 'or an internal line number' );
unlike( $err, qr/'true' expected/, 'or the decoder\'s own raw expectation' );

# --- valid JSON of the wrong shape is refused just as clearly -----------------

my $wrong_shape = File::Spec->catfile( $tmp, 'object.json' );
open $fh, '>', $wrong_shape or die $!;
print {$fh} '{"not": "an array"}';
close $fh;

( $status, $out, $err ) = run_cli(
    '--ref', $card->{ref}, '--author', 'claude', '--set-scope-in', $wrong_shape, '-o', 'json' );
isnt( $status, 0, 'valid JSON of the wrong shape is refused too' );
like( $err, qr/--set-scope-in/, 'naming the option' );
like( $err, qr/JSON array/i, 'and what it must contain, not merely that it decoded fine' );
like( $err, qr/not HASH/, 'and names the shape found instead, not a fallback label a bare-scalar case never reaches - '
      . 'the decoder refuses any bare scalar before this check runs' );

# --- the working case is unchanged --------------------------------------------

my $valid = File::Spec->catfile( $tmp, 'valid.json' );
open $fh, '>', $valid or die $!;
print {$fh} '["first item", "second item"]';
close $fh;

( $status, $out, $err ) = run_cli(
    '--ref', $card->{ref}, '--author', 'claude', '--set-scope-in', $valid, '-o', 'json' );
is( $status, 0, 'a real JSON array still succeeds' );
is( $err, '', 'with nothing on STDERR' );

done_testing();

__END__

=head1 NAME

t/741-a-decoder-that-named-itself.t - a --set-* array option's refusal
speaks in the caller's terms, not the JSON decoder's

=head1 DESCRIPTION

TKT-741. C<_json_array_input>, the shared boundary for all ten C<--set-*>
array options, decoded its file argument with no option name attached to
the error - so a bad file surfaced the JSON decoder's own internal
expectation ('true' expected, meaning nothing to a caller who never wrote
a bare C<true>) and an internal file and line number that moves every
release. The refusal now names the option, states that a JSON array is
required with an example, and points at the repeated single-item form
(C<--scope-in TEXT>, and so on for the other nine) as the append
alternative a caller reaching for C<--set-*> usually wanted anyway.

=cut
