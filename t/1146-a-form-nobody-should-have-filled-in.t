#!/usr/bin/env perl
# TKT-664, found by Codex review during TKT-625's own verify gate. TKT-625
# made every command but tira.import and tira.replace refuse --dry-run, in a
# guard inside _invoke that every writing path crosses - but tira.onboard
# -o browser crosses it LATE. run() resolves the browser endpoint and starts
# the disposable onboarding server (Tira::CLI::Serve::_serve_onboard_browser,
# or the injectable onboard_browser_server seam) before dispatch ever reaches
# _invoke's guard - the person fills in project name, members, columns and
# three prefixes on the served form, presses submit, and only THEN is told
# the flag is not implemented here. No project is written (the create
# callback still reaches _invoke's guard), but the form itself is a wasted
# round trip a person should never have been shown.
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
my $tira = Tira->new( clock => sub { '2026-09-21T00:00:00Z' } );

sub onboard_cli {
    my (@argv) = @_;
    my ( $out, $err, @calls ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = eval {
        Tira::CLI->run(
            command => 'onboard', argv => \@argv, tira => $tira,
            onboard_browser_server => sub { push @calls, { @_ }; return 1 },
        );
    };
    my $error = $@;
    return ( $status, $error, $out, $err, \@calls );
}

# --- the bug: the server starts before the flag is ever checked ------------

my ( $status, $error, $out, $err, $calls ) = onboard_cli( '-o', 'browser', '--dry-run' );

is( scalar @{$calls}, 0,
    'the onboard browser server is never started when --dry-run is present - '
      . 'the form should never be shown for a flag this command does not honour' );

# run() catches this the same way it catches _invoke's own dies - via
# _error(), which prints to STDERR and returns a status rather than
# propagating $@ - so the refusal is read from $err/$status, not from an
# uncaught exception.
is( $status, 2, 'and run() returns the same error status _error() gives every other refusal' );
like( $err, qr/--dry-run/,
    'and the printed refusal names the flag, before dispatch reaches the browser branch' );

is( $out, '', 'nothing is printed to stdout - refused before any output' );

# --- the wording matches every other command's identical refusal -----------
#
# Acceptance criterion 2: one definition, not two - so the message an
# onboard -o browser --dry-run caller sees is byte-identical to the one
# every ordinary command already gives via _invoke's own guard.

{
    my ( $ordinary_out, $ordinary_err ) = ( '', '' );
    open my $stdout, '>', \$ordinary_out or die $!;
    open my $stderr, '>', \$ordinary_err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $ordinary_status = Tira::CLI->run(
        command => 'ticket.create', argv => [ '--dry-run', '--title', 'x' ], tira => $tira,
    );
    like( $ordinary_err, qr/does not act on --dry-run/, 'an ordinary command\'s own refusal is read for comparison' );

    # Both refusals share the same text - "one definition, not two" is
    # what makes them byte-identical rather than two hand-kept sentences.
    like( $err, qr/\Qdoes not act on --dry-run:\E/, 'the onboard refusal uses the identical shared wording' );
}

# --- import and replace are unaffected, from either call site --------------

{
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new( name => 'DryRunProj', dir => $root, members => ['claude'] );
    local $ENV{TIRA_HOME} = $root;

    my $export_file = File::Spec->catfile( $tmp, 'export.jsonl' );
    open my $fh, '>', $export_file or die $!;
    close $fh;

    # run() catches a failing command's die internally (the same eval/
    # _error conversion the onboard case above goes through) and prints
    # to STDERR rather than leaving $@ set - so the refusal (or its
    # absence) is read from captured STDERR, not from $@.
    my ( $import_out, $import_err ) = ( '', '' );
    {
        open my $stdout, '>', \$import_out or die $!;
        open my $stderr, '>', \$import_err or die $!;
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        Tira::CLI->run( command => 'import', argv => [ '--file', $export_file, '--dry-run' ], tira => $tira );
    }
    # non-empty is the whole claim here: only that bulk_import was really
    # reached and said something, not which words - the empty export file
    # really does make it complain (malformed JSON), so this is not
    # vacuously true either.
    like( $import_err, qr/\S/, 'tira.import --dry-run reached bulk_import and it really did complain about something' );
    unlike( $import_err, qr/does not act on --dry-run/,
        'tira.import --dry-run is still accepted, not refused by this change' );

    my ( $replace_out, $replace_err ) = ( '', '' );
    {
        open my $stdout, '>', \$replace_out or die $!;
        open my $stderr, '>', \$replace_err or die $!;
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        Tira::CLI->run(
            command => 'replace', argv => [ '--pattern', 'x', '--with', 'y', '--dry-run' ], tira => $tira );
    }
    # non-empty is the whole claim here too, the same way as import above:
    # only that replace_records was really reached and printed something.
    like( $replace_err . $replace_out, qr/\S/, 'tira.replace --dry-run reached replace_records and it printed something' );
    unlike( $replace_err, qr/does not act on --dry-run/,
        'tira.replace --dry-run is still accepted too' );
}

# --- a plain onboard -o browser, with no --dry-run, is unaffected ----------

( $status, $error, $out, $err, $calls ) = onboard_cli( '-o', 'browser' );
is( $error, '', 'an ordinary onboard -o browser (no --dry-run) is not refused' );
is( scalar @{$calls}, 1, 'and the server DOES start for the ordinary case' );

done_testing;

__END__

=head1 NAME

1146-a-form-nobody-should-have-filled-in.t - onboard -o browser --dry-run is
refused before the server starts

=head1 DESCRIPTION

TKT-664. C<tira.onboard -o browser --dry-run> used to start the disposable
onboarding server and let a person fill in the whole form before the
C<--dry-run> refusal (which lives inside C<_invoke>, reached only on
submit) ever fired. C<run()> now refuses the flag for this path before
resolving the browser endpoint or starting the server at all, using the
same shared wording every other command's C<--dry-run> refusal already
gives. C<tira.import>/C<tira.replace>, the two commands that genuinely
honour C<--dry-run>, are unaffected from either call site.

=cut
