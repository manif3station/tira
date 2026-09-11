#!/usr/bin/env perl
# TKT-578. The ten --set-* replacement flags (--set-acceptance,
# --set-key-details, --set-deliverables, --set-test-steps, --set-bdd,
# --set-atdd, --set-labels, --set-affects-versions, --set-scope-in,
# --set-scope-out) all read a JSON array through lib/Tira/CLI.pm's
# _json_array_input, which wraps the file read AND the JSON
# decode in one eval - so an unreadable path and genuinely malformed JSON
# both landed on the identical "expects a JSON array, and '...' is not JSON"
# message, giving no hint that the real problem was the path itself, not its
# content.
#
# NARROWED FROM THE CARD'S ORIGINAL PREMISE, verified live before this test
# was written: the raw JSON::XS die with an absolute path and line number
# the card describes no longer reproduces - TKT-741 (2026-09-09) already
# wrapped that case in a clean Tira-worded refusal. What remains, and what
# this test covers, is the narrower gap acceptance criterion 2 names: the
# unreadable-path case should say a JSON file or - is expected, not read as
# "not JSON" (which suggests the path WAS read, and its content was bad).
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir tempfile);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    name => 'set flags', dir => $root, members => ['claude'],
    columns => ['backlog, done'], sow_prefix => 'SFS', epic_prefix => 'SFE', ticket_prefix => 'SFT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'x' );

local $ENV{TIRA_HOME} = $root;
local $ENV{TIRA_AUTHOR} = 'claude';

sub run_update {
    my (@extra_argv) = @_;
    my ( $out, $err ) = ( '', '' );
    my $status;
    {
        open my $ofh, '>', \$out or die $!;
        open my $efh, '>', \$err or die $!;
        local *STDOUT = $ofh;
        local *STDERR = $efh;
        $status = Tira::CLI->run(
            command => 'record.update', type => 'ticket',
            argv => [ '--ref', $card->{ref}, @extra_argv ],
        );
    }
    return ( $status, $out, $err );
}

# Same as run_update, but with $stdin fed to the command's own STDIN - the
# '-' input form _text_input reads from *STDIN directly.
sub run_update_with_stdin {
    my ( $stdin, @extra_argv ) = @_;
    open my $ifh, '<', \$stdin or die $!;
    local *STDIN = $ifh;
    return run_update(@extra_argv);
}

# --- an unreadable path: prose typed where a filename was expected ---------

{
    my ( $status, undef, $err ) = run_update( '--set-acceptance', 'just some text' );
    isnt( $status, 0, 'inline prose passed to --set-acceptance is refused' );
    like( $err, qr/JSON file|for stdin/i,
        'and the refusal says a JSON file or - is expected' );
    unlike( $err, qr/is not JSON/i,
        'not the "is not JSON" wording - the path was never read, so this is not a content complaint' );
    unlike( $err, qr/No such file or directory|Cannot read/i,
        'and not a raw missing-file message either' );
}

# --- a readable path whose content is not JSON ------------------------------

{
    my ( $fh, $path ) = tempfile( DIR => $tmp, SUFFIX => '.txt' );
    print {$fh} "plain line one\nplain line two\n";
    close $fh;

    my ( $status, undef, $err ) = run_update( '--set-acceptance', $path );
    isnt( $status, 0, 'a readable file with non-JSON content is refused' );
    like( $err, qr/is not JSON/i, 'and the refusal says the content is not JSON' );
    unlike( $err, qr/\bat\s+\S+\s+line\s+\d+/i,
        'with no internal file/line trailer from inside the skill' );
    unlike( $err, qr{/lib/Tira}, 'and no absolute path into the installed skill' );
}

# --- a JSON object rather than an array: unchanged --------------------------

{
    my ( $fh, $path ) = tempfile( DIR => $tmp, SUFFIX => '.json' );
    print {$fh} '{"not":"an array"}';
    close $fh;

    my ( $status, undef, $err ) = run_update( '--set-acceptance', $path );
    isnt( $status, 0, 'a JSON object is still refused' );
    like( $err, qr/expects a JSON array, not HASH/i,
        'with the existing, already-correct message, unchanged' );
}

# --- a valid JSON array, and the same via stdin, both still work -----------

{
    my ( $fh, $path ) = tempfile( DIR => $tmp, SUFFIX => '.json' );
    print {$fh} '["one", "two"]';
    close $fh;

    my ( $status, $out, $err ) = run_update( '--set-acceptance', $path, '-o', 'json' );
    is( $status, 0, 'a valid JSON array file still works' );
    like( $out, qr/"one"/, 'and the first item landed' );
}

{
    my ( $status, $out, $err ) = run_update_with_stdin( '["three", "four"]', '--set-acceptance', '-', '-o', 'json' );
    is( $status, 0, 'a valid JSON array piped via - still works' );
    like( $out, qr/"three"/, 'and its first item landed' );
}

done_testing;

__END__

=head1 NAME

t/1069-a-json-file-that-was-never-there.t - the --set-* flags distinguish an
unreadable path from genuinely malformed JSON content

=head1 DESCRIPTION

TKT-578. C<_json_array_input> wrapped the file read and the JSON decode in
one C<eval>, so a path that could not be read and a path that could be read
but held bad JSON produced the identical "is not JSON" message - the wrong
answer for the first case, since the path was never actually read. Split
into two checks: an unreadable path (or unreadable stdin) says a JSON file
or C<-> is expected; a readable path with bad content still says its content
is not JSON, with no internal file/line trailer. The existing "not an array"
refusal for a JSON object is unchanged, and both a valid file and stdin still
work.

=cut
