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

# --- MUST NOT REGRESS: internal callers of policy_declined() stay -----------
# --- board-wide-only, unaffected by the CLI-only merge above (Codex --------
# --- review caught an earlier draft that merged unconditionally, breaking --
# --- policy_review's own t/470/TKT-800 contract) ----------------------------

my $review = $tira->policy_review( project => $root );
is( scalar @{ $review->{declined} }, 1,
    'policy_review still reports exactly the one board-wide decline, not the per-card one mixed in' );
is( scalar @{ $review->{declined_per_card} }, 1,
    'the per-card decline still shows up in ITS OWN dedicated key, unaffected' );

my $undeclared = $tira->policy_undeclared( project => $root );
ok( ( grep { $_ eq 'checklist-idle' } @{$undeclared} ),
    'checklist-idle is still reported as undeclared board-wide - the per-card-only decline on one card does not wrongly mark the RULE as answered for the whole board' );

done_testing();

__END__

=head1 NAME

789-a-count-that-only-heard-half-the-board.t - policy.declined with no
--ref reports both board-wide and per-card declines, not just the
board-wide subset

=head1 DESCRIPTION

TKT-789. C<tira.policy.declined> with no C<--ref> used to read only
C<declined_policies> (board-wide), silently omitting every real,
stored per-card decline in C<card_declines> - a caller asking "what is
declined on this board?" got a number that under-counted, with nothing
in the output indicating it was scoped. The CLI command now merges in
every per-card decline alongside the board-wide ones, via a new
C<merge_card_declines> opt-in parameter on C<policy_declined()> set
only by the CLI dispatch. C<--ref> itself already worked correctly
(returning only that card's own declines) and is unaffected; it was
also entirely undocumented in the usage line, now fixed alongside the
omission.

A first draft merged card_declines into C<policy_declined()>'s base
return unconditionally, which Codex review caught as a real
regression: every INTERNAL caller (C<policy_review>, C<policy_undeclared>,
C<_police_pass_body>'s card-damaged/card-unreadable suppression) relies
on the no-ref shape staying board-wide-only, and mixing per-card
entries in broke each of them - confirmed by running the existing
C<t/470> (TKT-800) test, which failed outright. C<merge_card_declines>
is opt-in and set only by the C<policy.declined> CLI command, so every
internal caller is completely unaffected.

=cut
