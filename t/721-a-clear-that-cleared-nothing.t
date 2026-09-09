#!/usr/bin/env perl
# tira.warning.clear --all is the idempotent "clear everything" verb, and on
# a board with nothing to clear it fails three ways at once.
#
# TKT-520 hourly bug hunt, 2026-08-29. warning_clear's empty-result branch
# treats --all exactly like --id: `die "Warning '$args{id}' not found\n" if
# !@removed;`. For --all, $args{id} is undef, so a board with no warnings
# (or one that has already been cleared once) gets a Perl uninitialized-value
# warning on STDERR, a refusal naming an id nobody supplied, and exit 2 for
# a request that had nothing to do and was already satisfied.
#
# _warning_read returns [] for a board with no warnings file at all, so the
# empty case needs no unusual state - a fresh board is enough, and so is
# running the clear twice. t/47-warning.t tests --all only with a warning
# present and the not-found refusal only through --id, so this is the gap
# between the two tests that already exist.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-09T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'A clear that cleared nothing', dir => $root, columns => ['Backlog, Doing'] );

sub run_cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => 'warning.clear', argv => \@argv );
    return ( $status, $out, $err );
}

# --- --all on a board that has never had a warning ---------------------------

my ( $status, $out, $err ) = run_cli( '--all', '-o', 'json' );

is( $status, 0, '--all on a board with no warnings exits 0, not 2' );
is_deeply( ( eval { decode_json($out) } // 'unparseable' ), [],
    'and returns an empty list, not a refusal' );
is( $err, '', 'with no Perl warning reaching STDERR' );

# --- --all run twice: the second run is the same empty case ------------------

$tira->warning_add( project => $root, message => 'One warning' );
run_cli( '--all', '-o', 'json' );    # first clear: removes the one warning
( $status, $out, $err ) = run_cli( '--all', '-o', 'json' );

is( $status, 0, 'a second --all on an already-empty board still exits 0' );
is_deeply( ( eval { decode_json($out) } // 'unparseable' ), [], 'still an empty list' );
is( $err, '', 'still no Perl warning' );

# --- --id keeps exactly the refusal it has today ------------------------------
#
# The fix must separate the two cases, not weaken the one that should refuse.

( $status, $out, $err ) = run_cli( '--id', '99', '-o', 'json' );
isnt( $status, 0, '--id for a warning that does not exist is still refused' );
like( $err, qr/Warning '99' not found/,
    'with the exact message it has today - an id WAS supplied here, so naming it is correct' );

done_testing();

__END__

=head1 NAME

t/721-a-clear-that-cleared-nothing.t - warning.clear --all on an empty board
succeeds instead of failing three ways at once

=head1 DESCRIPTION

TKT-721. C<warning_clear>'s empty-result branch treated C<--all> exactly like
C<--id>: dying with a message built from C<$args{id}>, which is undef for
C<--all>. That produced a Perl uninitialized-value warning, a refusal naming
an id nobody supplied, and a non-zero exit for an operation that had nothing
to clear and was therefore already done. The fix separates the two cases:
C<--id> keeps its exact refusal, and C<--all> with nothing to remove returns
an empty list and exits 0.

=cut
