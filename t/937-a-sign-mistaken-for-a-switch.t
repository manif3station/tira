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
# WRITTEN RED: no Getopt::Long::Configure call exists yet, so getopt_compat
# is still active and this reproduces against the pre-fix code.

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
itself, failing with "Unknown option: ...". C<Getopt::Long::Configure(qw(no_getopt_compat))>
removes C<+> from that prefix pattern, fixing this while leaving C<->
(genuinely still an option prefix, unaffected) and the existing bare-flag
pattern (C<--title -o browser>) completely unchanged. A leading C<->
value still requires the C<--title=VALUE> equals form - that is standard,
expected getopt behavior for every CLI tool and is unrelated to this fix.

=cut
