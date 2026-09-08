#!/usr/bin/env perl
# TKT-696. There were two standards for a finished card, and only one of
# them could be asked about. tira.card.required/tira.ticket.missing
# answered from @CARD_REQUIRED; tools/card-holes' unproven() separately
# demanded a gate_passing_log, an evidence entry, and (past push) a
# fix_version - none of which is in @CARD_REQUIRED, so ticket.missing
# reported nothing missing on a card the push gate was about to refuse.
#
# card_required now carries the second standard too, keyed by the
# milestone past which each field is owed; ticket.missing and card_holes
# both read it, so the two answers cannot drift apart again.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-09-08T17:00:00Z'} );
$tira->project_new(
    name => 'Proven', dir => $root, members => ['claude'],
    columns => ['backlog, implement, verify, push, done'],
    sow_prefix => 'PVS', epic_prefix => 'PVE', ticket_prefix => 'PVT',
);

# --- the definition names the second standard too ---------------------------

my $answer = Tira->card_required;
is( ref $answer->{past_column}, 'HASH', 'card_required carries what a card owes past a milestone' );
ok( exists $answer->{past_column}{gate_passing_log}, 'names gate_passing_log' );
ok( exists $answer->{past_column}{evidence}, 'names evidence' );
ok( exists $answer->{past_column}{fix_version}, 'names fix_version' );

# --- a card in verify with no gate or evidence: ticket.missing says so ------

my $epic = $tira->create_record( project => $root, type => 'epic', title => 'Home for these' );

sub full_card {
    my ($title) = @_;
    my $card = $tira->create_record( project => $root, type => 'ticket', title => $title );
    $tira->record_update(
        project => $root, ref => $card->{ref}, author => 'claude',
        description => 'd', problem_or_feature => 'p', solution_needed => 's',
        key_details => ['k'], deliverables => ['d'], acceptance => ['a'],
        test_steps => ['t'], bdd => ['b'], atdd => ['a'], priority => 3,
        scope => { included => ['in'], excluded => ['out'] },
    );
    $tira->checklist_add( project => $root, ref => $card->{ref}, author => 'claude', item => 'x', status => 'pending' );
    $tira->hierarchy_link( project => $root, author => 'claude', parent => $epic->{ref}, child => $card->{ref} );
    return $card;
}

my $backlog_card = full_card('Still in backlog, no gate, no evidence');
my $backlog_said = $tira->record_missing( project => $root, ref => $backlog_card->{ref} );
ok( !( grep { $_ eq 'gate_passing_log' || $_ eq 'evidence' } @{ $backlog_said->{missing} } ),
    'a backlog card is not asked for gate/evidence - it has not reached the milestone yet' );

my $unproven = full_card('No gate, no evidence');
$tira->record_move( project => $root, author => 'claude', ref => $unproven->{ref}, column => 'implement' );
$tira->record_move( project => $root, author => 'claude', ref => $unproven->{ref}, column => 'verify' );

my $said = $tira->record_missing( project => $root, ref => $unproven->{ref} );
ok( ( grep { $_ eq 'gate_passing_log' } @{ $said->{missing} } ), 'ticket.missing now names the missing gate' );
ok( ( grep { $_ eq 'evidence' } @{ $said->{missing} } ), 'and the missing evidence' );
ok( !( grep { $_ eq 'fix_version' } @{ $said->{missing} } ), 'but not fix_version - verify is before push' );

# --- proving it settles the finding, in ticket.missing and card_holes ------

$tira->release_record(
    project => $root, author => 'claude', ref => $unproven->{ref},
    gate => 'suite', result => 'pass', details => 'green', evidence => 'log', fix_version => '1.0',
);
my $settled = $tira->record_missing( project => $root, ref => $unproven->{ref} );
is_deeply( $settled->{missing}, [], 'proven, ticket.missing says nothing is missing' );

my @holes = grep { $_->{ref} eq $unproven->{ref} } @{ $tira->card_holes( project => $root ) };
is( scalar @holes, 0, 'and card_holes agrees - the board sweep sees the same thing' );

# --- a card in an ENDED column is exempt, the same exemption unproven() had -

my $done_card = full_card('Finished before this check existed');
for my $column (qw(implement verify push done)) {
    $tira->record_move( project => $root, author => 'claude', ref => $done_card->{ref}, column => $column );
}
my $done_said = $tira->record_missing( project => $root, ref => $done_card->{ref} );
ok( !( grep { $_ eq 'gate_passing_log' || $_ eq 'evidence' || $_ eq 'fix_version' } @{ $done_said->{missing} } ),
    'a card in an ended column is exempt from the second standard, same as unproven()' );

# --- and card-holes keeps no list of its own, the way t/224 already asserts
# it for the first definition --------------------------------------------

{
    open my $tool, '<', 'tools/card-holes' or die "card-holes: $!";
    my $text = do { local $/; <$tool> };
    close $tool;

    like( $text, qr/past_column\(\)/, 'unproven() reads the second standard from the engine' );
    unlike( $text, qr/if not record\.get\('gate_passing_log'\)/,
        'and no longer checks gate_passing_log unconditionally, on its own say-so' );
}

done_testing();

__END__

=head1 NAME

696-a-standard-nobody-could-ask-about.t - the push gate's own definition of
proven is now part of the one askable definition of a complete card

=head1 DESCRIPTION

TKT-696. C<tools/card-holes>' C<unproven()> demanded a gate entry, an
evidence entry, and (past push) a fix version - none of which
C<tira.card.required> named, so C<tira.ticket.missing> answered empty on
a card the push gate was about to refuse. C<card_required> now carries
a C<past_column> table naming each field and the milestone role/column
past which it is owed; C<record_missing> (C<tira.ticket.missing>) and
C<card_holes> both read it, exempting a card already in an ended column
the same way C<unproven()> always did.

=cut
