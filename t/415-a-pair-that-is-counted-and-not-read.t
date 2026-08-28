#!/usr/bin/env perl

# Marking done costs evidence. The gate counts the evidence; it never reads it.
#
# TKT-453 made a done claim cost a --command/--proof pair, and both documents
# say so - docs/commands.md: "marking --status done (case-insensitively) refuses
# without at least one --command/--proof pair". It refuses without a pair. It
# does not check that the pair says anything.
#
# Measured on a scratch board, five shapes, all ACCEPTED:
#
#   ('', '')                              both halves empty
#   ('x', '   ')                          whitespace-only proof
#   ('', 'real output')                   empty command
#   ('prove -l t', '')                    empty proof
#   ('prove -l t', 'All tests successful')  the only one that should pass
#
# So the cheapest way past a gate is to supply nothing at all, which takes less
# effort than doing the work and less effort than the duplicate proof TKT-583
# was filed about - a duplicate at least requires text that once described
# something real.
#
# The check belongs in _proof_entries_for (lib/Tira.pm:5211), which is where the
# pair requirement is already raised and which both checklist_update and
# required_item_update call. Putting it anywhere else lets the CLI and the
# engine disagree, and the card records that the fault reproduces at both.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-28T07:20:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name          => 'Pairs',  dir         => $root,
    members       => ['ada'],  columns     => ['backlog, done'],
    sow_prefix    => 'PRS',    epic_prefix => 'PRE',
    ticket_prefix => 'PRT',    author      => 'ada',
);

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card with things to prove', author => 'ada',
);
my $ref = $card->{ref};

$tira->checklist_add(
    project => $root, type => 'ticket', ref => $ref,
    item => 'Prove the thing', status => 'To Do', author => 'ada',
);
$tira->required_item_add(
    project => $root, type => 'ticket', ref => $ref,
    item => 'Prove the other thing', column => 'backlog', status => 'pending', author => 'ada',
);

sub status_of {
    my ($which) = @_;
    my $record = $tira->record_show( project => $root, type => 'ticket', ref => $ref );
    return $which eq 'checklist'
      ? ( $record->{checklist}[0]{status}       // '' )
      : ( $record->{required_items}[0]{status}  // '' );
}

# Marking done through whichever of the two commands is named, returning the
# refusal text or undef when it was accepted. Both go through
# _proof_entries_for, so one fix has to serve both and one test can hold both.
sub mark_done {
    my ( $which, $command, $proof ) = @_;
    my %args = (
        project => $root, type => 'ticket', ref => $ref, status => 'done',
        command => [$command], proof => [$proof], author => 'ada',
    );
    my $ok = eval {
        $which eq 'checklist'
          ? $tira->checklist_update( %args, id => 'CHK-001' )
          : $tira->required_item_update( %args, id => 'REQ-001' );
        1;
    };
    return $ok ? undef : ( $@ || 'died with no message' );
}

# --- the control: a real pair still works ------------------------------------
#
# First, so the refusals below cannot pass on a board where marking done is
# broken for some unrelated reason.

for my $which (qw(checklist required)) {
    my $refusal = mark_done( $which, 'prove -l t/415.t', 'All tests successful. Files=1, Result: PASS' );
    is( $refusal, undef, "$which: a pair with content on both sides is accepted" );
    is( lc status_of($which), 'done', "$which: and the item is marked done" );
}

# Put them back, so each shape below is judged against an unmarked item.
sub reset_items {
    $tira->checklist_update(
        project => $root, type => 'ticket', ref => $ref,
        id => 'CHK-001', status => 'To Do', author => 'ada',
    );
    $tira->required_item_update(
        project => $root, type => 'ticket', ref => $ref,
        id => 'REQ-001', status => 'pending', author => 'ada',
    );
    return;
}

# --- the four shapes that must be refused ------------------------------------
#
# Named rather than looped anonymously, because the third acceptance criterion
# is that the refusal says WHICH half was empty, and that cannot be asserted
# without knowing which half this case emptied.

my @shapes = (
    # Both halves, not just one: a guard that named only --command here would be
    # wrong about --proof and still satisfy a single-pattern check. Codex review
    # caught that this list originally asked for qr/command/i alone.
    { name => 'both halves empty',    command => '',              proof => '',
      names => [ qr/command/i, qr/proof/i ] },
    { name => 'whitespace-only proof', command => 'prove -l t',    proof => "   \t ",
      names => [ qr/proof/i ] },
    { name => 'empty command',        command => '',              proof => 'real captured output',
      names => [ qr/command/i ] },
    { name => 'empty proof',          command => 'prove -l t',    proof => '',
      names => [ qr/proof/i ] },
);

for my $shape (@shapes) {
    for my $which (qw(checklist required)) {
        reset_items();
        my $refusal = mark_done( $which, $shape->{command}, $shape->{proof} );
        ok( defined $refusal, "$which: $shape->{name} is refused" );
        for my $names ( @{ $shape->{names} } ) {
            like( $refusal // '', $names,
                "$which: the refusal names $names ($shape->{name})" );
        }
        isnt( lc status_of($which), 'done', "$which: and the item is NOT marked done ($shape->{name})" );
    }
}

# --- and the refusal is not the generic missing-pair message -----------------
#
# A pair WAS supplied. Answering an empty pair with "requires at least one
# --command/--proof pair" sends the caller to add the thing they already added.

reset_items();
my $empty_refusal = mark_done( 'checklist', '', '' );
# The subject is established with isnt() on the variable ITSELF rather than
# ok(defined $x): t/147 reads the first argument of the establishing assertion,
# so 'defined $x' establishes nothing as far as the scan is concerned - and it
# is right to be strict, because a denial about a variable is only meaningful
# if that variable was checked under its own name.
isnt( $empty_refusal, undef, 'an empty pair is refused at all, so the denial below has a subject' );
unlike( $empty_refusal, qr/requires at least one/,
    'and it is not answered with the message for a MISSING pair - one was supplied' );

done_testing();

__END__

=head1 NAME

t/415-a-pair-that-is-counted-and-not-read.t - marking done must cost evidence
that says something, not merely a pair of arguments

=head1 DESCRIPTION

C<_proof_entries_for> raises the pair requirement TKT-453 introduced and never
looks inside the pair, so C<--command '' --proof ''> marks any item done at the
CLI and in the engine alike.

The control runs first and deliberately: four refusals prove nothing on a board
where marking done is broken for an unrelated reason, so the accepted case is
asserted before any of them.

The refusals are enumerated rather than looped over a list of empties because
the card requires the message to name WHICH half was empty, which cannot be
checked without knowing which half each case emptied.

=cut
