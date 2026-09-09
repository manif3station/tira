#!/usr/bin/env perl
# A command line carrying leftover positional arguments (words that are not
# options and not values of options) is refused with the bare
# "Invalid command-line options" - naming neither which word, nor how
# many, nor that the fault is a leftover argument at all, even though the
# branch that raises it already holds those words in @{$argv}.
#
# Measured live in this session: a shell quoting slip turned one --bdd
# value into about a dozen bare words, and a whole ticket.create carrying
# a title, problem, solution, 5 acceptance criteria, 4 deliverables, 5 key
# details, scope and test steps was discarded with four words of
# explanation.
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
my $tira = Tira->new( clock => sub { '2026-09-09T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'A command that said nothing wrong', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'CSN', epic_prefix => 'CSE', ticket_prefix => 'CST',
);

sub run_cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => 'record.create', type => 'ticket', tira => $tira, argv => \@argv );
    };
    return ( $status, $out, $err );
}

# --- one stray word --------------------------------------------------------

my ( $status, $out, $err ) = run_cli( '--title', 'Real title', 'stray' );
isnt( $status, 0, 'a leftover argument is still refused' );
isnt( $err, '', 'the refusal is not empty' );
like( $err, qr/\bstray\b/, 'the refusal names the leftover word verbatim' );
like( $err, qr/quot/i, 'and names quoting as the likely cause' );

# --- a value split into several words by a quoting mistake ------------------

( $status, $out, $err ) = run_cli(
    '--title', 'Real title', 'Given', 'a', 'title', 'When', 'a', 'card', 'Then', 'it', 'exists' );
isnt( $status, 0, 'a split value is still refused' );
like( $err, qr/\bGiven\b/, 'the first leftover word is named' );
like( $err, qr/\band 8 more\b/, 'the refusal says how many additional words followed (8 more, after the first of 9)' );

# --- control: an unknown option still wins when both faults are present ----

( $status, $out, $err ) = run_cli( '--title', 'Real title', '--bogus-flag', 'x', 'stray' );
isnt( $status, 0, 'still refused' );
like( $err, qr/Unknown option:\s*bogus-flag/, 'the unknown-option message is the one given, naming the bad flag' );
unlike( $err, qr/\bstray\b/, 'not the leftover-argument message, when both faults are present' );

# --- control: a valid command line is unaffected ----------------------------

( $status, $out, $err ) = run_cli( '--title', 'A perfectly good title' );
is( $status, 0, 'a valid command line still succeeds' );
is( $err, '', 'with nothing on STDERR' );

done_testing();

__END__

=head1 NAME

t/759-a-command-that-said-nothing-wrong.t - a leftover command-line
argument is refused by name, not by a bare fallback

=head1 DESCRIPTION

TKT-759. C<lib/Tira/CLI.pm>'s option-parsing branch already holds the
leftover words in C<@{$argv}> when it refuses a command line, but only an
unrecognised OPTION got a message naming anything (TKT-298, via a
Getopt::Long warning) - a leftover ARGUMENT left no warning, so the
refusal fell through to the bare "Invalid command-line options". The
branch now names the first leftover word, how many followed it, and
quoting as the likely cause, while the unknown-option message (TKT-298)
still wins when both faults are present on the same command line.

=cut
