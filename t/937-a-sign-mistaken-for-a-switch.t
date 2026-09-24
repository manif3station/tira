#!/usr/bin/env perl
# TKT-937. --title takes an OPTIONAL Getopt::Long argument ('title:s'), used
# by commands like `dashboard.ticket --title -o browser` where --title is a
# bare toggle with no value. Getopt::Long's default getopt_compat setting
# treats a leading '+' as an option-introducing prefix, the same as '-', so
# an optional-argument option refuses to consume a next token that starts
# with '+' as its value - `--title '+16.17 adjustment'` leaves title empty
# and then tries to parse '+16.17 adjustment' as a bogus option itself,
# failing with "Unknown option: 16.17". Found via a real card that could
# never be created (a positive-amount adjustment whose auto-built title
# happened to start with '+').
#
# WRITTEN RED: no rewrite of a --title/+VALUE pair exists yet, so this
# reproduces against the pre-fix code.
#
# Codex review, first draft: disabling getopt_compat outright (an earlier
# version of this fix) silently broke the OTHER thing that setting controls -
# the '+foo'/'+no-foo' spelling for every negatable ('!') option in the same
# @spec (with-questions, repair, watch, terminal, queue), and unknown-option
# detection for a bogus '+flag'. This file's own regression assertions below
# (the "must not regress" section) exist specifically to catch that class of
# fix again, not just prove the original bug is gone.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-09-24T20:00:00Z'} );
$tira->project_new(
    name => 'A sign mistaken for a switch', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'PSW', epic_prefix => 'PSE', ticket_prefix => 'PST',
);

sub run_cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => 'record.create', type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

# --- THE BUG: a leading '+' in a space-separated --title value ------------

my ( $status, $out, $err ) = run_cli(
    '--title', '+16.17 adjustment', '--author', 'claude', '--reporter', 'claude',
    '--source', 'test', '--description', 'test', '-o', 'json' );

is( $status, 0, 'a --title value starting with a literal + (space-separated) is accepted' )
  or diag("stderr was: $err");
unlike( $err, qr/Unknown option/, 'no spurious "Unknown option" refusal' );
like( $out, qr/\Q+16.17 adjustment\E/, 'the title is stored verbatim, including the leading +' );

# --- a genuinely unknown option still refuses, unchanged -------------------

( $status, $out, $err ) = run_cli(
    '--title', 'ordinary title', '--author', 'claude', '--reporter', 'claude',
    '--source', 'test', '--description', 'test', '--bogus-flag-xyz', 'value', '-o', 'json' );
isnt( $status, 0, 'a genuinely unknown option is still refused' );
like( $err, qr/Unknown option/, 'still names it as an unknown option' );

# --- other =s-style text options with a leading + already worked and still do

( $status, $out, $err ) = run_cli(
    '--title', 'plain title', '--description', '+something', '--author', 'claude',
    '--reporter', 'claude', '--source', 'test', '-o', 'json' );
is( $status, 0, 'a mandatory =s option (--description) with a leading + still succeeds, unaffected' );
like( $out, qr/\Q+something\E/, 'and stores the value verbatim' );

# --- bare --title (optional, no value) followed by another option is unaffected

( $status, $out, $err ) = run_cli(
    '--title', '--author', 'claude', '--reporter', 'claude',
    '--source', 'test', '--description', 'test', '-o', 'json' );
isnt( $status, 0, 'a bare --title (dash-prefixed next token) still refuses - title ends up empty, not swallowing --author\'s value' );
unlike( $err, qr/Unknown option/, 'the refusal is a normal missing-title validation, not a parse-level "Unknown option" - --author was still parsed correctly as its own option' );

# --- MUST NOT REGRESS: getopt_compat's '+foo'/'+no-foo' negatable-option ---
# --- spelling, and '+bogus' unknown-option detection, both caught by  -----
# --- Codex review on this ticket's first (disable-getopt_compat) draft. ---

use Getopt::Long qw(GetOptionsFromArray);

{
    my @argv = ('+repair');
    my %opt;
    my $ok = GetOptionsFromArray( \@argv, 'repair!' => \$opt{repair} );
    ok( $ok, '+repair still parses successfully (getopt_compat negation spelling untouched)' );
    is( $opt{repair}, 1, 'and still sets the negatable option to 1, exactly as before this ticket' );
}
{
    my @argv = ('+no-repair');
    my %opt;
    my $ok = GetOptionsFromArray( \@argv, 'repair!' => \$opt{repair} );
    ok( $ok, '+no-repair still parses successfully' );
    is( $opt{repair}, 0, 'and still sets the negatable option to 0' );
}
{
    my @argv = ('+bogus');
    my %opt;
    local $SIG{__WARN__} = sub { };
    my $ok = GetOptionsFromArray( \@argv, 'repair!' => \$opt{repair} );
    ok( !$ok, 'a genuinely unknown +-prefixed option is still refused (getopt_compat unknown-option detection untouched)' );
}

done_testing();

__END__

=head1 NAME

937-a-sign-mistaken-for-a-switch.t - a --title value starting with a
literal '+' is accepted rather than misparsed as an unknown option

=head1 DESCRIPTION

TKT-937. C<--title> is declared with an OPTIONAL Getopt::Long argument
spec (C<title:s>), needed so a bare C<--title> (with no value at all,
immediately followed by another option) works as a toggle. Getopt::Long's
default C<getopt_compat> setting treats a leading C<+> as an
option-introducing prefix the same as C<->, so for an optional-argument
option it refuses to consume a next token starting with C<+> as the
value - the token is left unconsumed and then misparsed as a bogus option
itself, failing with "Unknown option: ...".

A first draft of this fix disabled C<getopt_compat> outright
(C<Getopt::Long::Configure(qw(no_getopt_compat))>), which Codex review
caught as a real regression: that setting also controls the C<+foo>/
C<+no-foo> spelling for every negatable (C<!>) option in the CLI's shared
option spec, and disabling it silently broke C<+repair> (stopped setting
anything at all) and unknown-option detection for a bogus C<+flag>
(stopped being reported as "Unknown option"). The actual fix instead
rewrites a literal C<--title> argv element immediately followed by a
C<+>-leading element into a single C<--title=VALUE> element, before
Getopt::Long ever sees it - identical to typing the equals form by hand,
and scoped to C<--title> alone (the only optional-argument option in the
spec). C<getopt_compat> itself, and every other option's behavior, is
completely untouched. A leading C<-> value still requires the
C<--title=VALUE> equals form - that is standard, expected getopt behavior
for every CLI tool and is unrelated to this fix.

=cut
