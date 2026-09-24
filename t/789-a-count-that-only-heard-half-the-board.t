#!/usr/bin/env perl
# TKT-789. tira.policy.declined with no --ref returns ONLY board-wide
# declines (data->{declined_policies}) - a per-card decline
# (data->{card_declines}) is silently omitted, though it is real, stored,
# and read back correctly when --ref IS given. The unfiltered call does
# not error or warn that it is scoped; it returns a short, plausible list
# that under-counts. Separately, --ref is a real, working filter but is
# entirely undocumented in the usage line.
#
# WRITTEN RED: policy_declined's no-ref branch (lib/Tira.pm) only reads
# declined_policies, so this reproduces against the pre-fix code.

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
my $tira = Tira->new( clock => sub {'2026-09-24T22:00:00Z'} );
$tira->project_new(
    name => 'A count that only heard half the board', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'PCB', epic_prefix => 'PCE', ticket_prefix => 'PCT',
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
    my $status = Tira::CLI->run( command => 'policy.declined', argv => \@argv );
    return ( $status, $out, $err );
}

# --- THE BUG: a board-wide decline and a per-card decline both exist -----

$tira->policy_decline(
    project => $root, rule => 'card-stalled', reason => 'not applicable here', author => 'claude' );
$tira->policy_decline(
    project => $root, rule => 'checklist-idle', ref => $card->{ref},
    reason => 'this card is intentionally idle', author => 'claude' );

my ( $status, $out, $err ) = run_cli( '-o', 'json' );
is( $status, 0, 'policy.declined with no --ref succeeds' );
like( $out, qr/card-stalled/, 'the board-wide decline is present' );
like( $out, qr/checklist-idle/, 'the per-card decline is ALSO present - not silently omitted' );
like( $out, qr/\Q$card->{ref}\E/, 'the per-card decline names the card it belongs to' );

# --- the --ref filter still works exactly as before, unaffected ----------

( $status, $out, $err ) = run_cli( '--ref', $card->{ref}, '-o', 'json' );
is( $status, 0, 'policy.declined --ref REF succeeds' );
like( $out, qr/checklist-idle/, 'still returns the per-card decline' );
unlike( $out, qr/card-stalled/, 'and still excludes the board-wide decline, unaffected by this fix' );

# --- --ref is documented in the usage line --------------------------------

require Tira::CLI::Usage;
my $usage = Tira::CLI::Usage::_usage('policy.declined');
like( $usage, qr/--ref/, 'the usage line names --ref' );

done_testing();

__END__

=head1 NAME

789-a-count-that-only-heard-half-the-board.t - policy.declined with no
--ref reports both board-wide and per-card declines, not just the
board-wide subset

=head1 DESCRIPTION

TKT-789. C<policy_declined>'s no-C<--ref> branch used to read only
C<declined_policies> (board-wide), silently omitting every real,
stored per-card decline in C<card_declines> - a caller asking "what is
declined on this board?" got a number that under-counted, with nothing
in the output indicating it was scoped. The no-ref result now merges
in every per-card decline alongside the board-wide ones. C<--ref>
itself already worked correctly (returning only that card's own
declines) and is unaffected; it was also entirely undocumented in the
usage line, now fixed alongside the omission.

=cut
