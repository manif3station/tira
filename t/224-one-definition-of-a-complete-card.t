#!/usr/bin/env perl
# What a complete card is, decided once.
#
# Police and the push gate each carried their own list and the two disagreed in
# both directions at once. Demonstrated on one card on a scratch board, filled
# in until only two things were absent: police said "missing: description" and
# tools/card-holes, run against the same board seconds later, said "missing:
# parent". Neither mentioned the other's field.
#
# Both cost hours the night this was written. The bridge nagged about
# description on cards the gate calls finished - noise, on the channel whose
# noise is the subject of another card - and three push attempts died on a
# missing parent police had never once mentioned.
#
# So the engine owns the definition and says what it is. The gate asks rather
# than keeping a copy, which is the only arrangement where the two cannot drift
# again.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );

my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );
$tira->project_new(
    name => 'Complete', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'CPS', epic_prefix => 'CPE', ticket_prefix => 'CPT',
);

# --- the definition, in one place ------------------------------------------

my $required = Tira->card_required;
is( ref $required, 'ARRAY', 'there is one definition of a complete card' );
ok( scalar @{$required}, 'and it names fields' );

for my $field (qw(problem_or_feature solution_needed key_details deliverables
    acceptance_criteria test_steps bdd atdd description priority
    scope_in scope_out checklist parent)) {
    ok( scalar( grep { $_ eq $field } @{$required} ), "it names $field" );
}

# --- and both readers use it ------------------------------------------------
#
# The gate is a separate program in a separate language, so it cannot share a
# variable - it can only ask. Asserted by reading it, because what matters is
# that it has no list of its own to drift.

{
    open my $tool, '<', 'tools/card-holes' or die "card-holes: $!";
    my $text = do { local $/; <$tool> };
    close $tool;

    unlike( $text, qr/^REQUIRED\s*=\s*\[/m,
        'the push gate keeps no list of its own' );
    # It asks the tree rather than the installed copy, because this gate runs
    # before the push that makes the new code installable - asking d2 for a
    # command that arrives with this release would refuse the release that
    # introduces it.
    like( $text, qr{skills.,\s*'card',\s*'cli',\s*'required'},
        'and asks the tree it is gating for the one there is' );
}

# --- and asked the way anything else asks it -------------------------------
#
# Through the command, because the reader that needs it most is a separate
# program in another language and a list nothing outside this file can reach is
# not a definition anybody else can share.

{
    require Tira::CLI;
    my $out = '';
    open my $capture, '>', \$out or die $!;
    {
        local *STDOUT = $capture;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => 'card.required', tira => $tira, argv => [ '-o', 'json' ] );
    }

    # non-empty is the whole claim: a precondition for the assertion below,
    # which would pass against a command that printed nothing at all.
    like( $out, qr/\S/, 'the command answers' );
    like( $out, qr/problem_or_feature/, 'with the definition the engine holds' );
    like( $out, qr/checklist/, 'including the fields the gate used to want alone' );
}

# --- the same card, the same answer ----------------------------------------

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Missing exactly one thing' );

my $missing = $tira->card_missing( project => $root, ref => $card->{ref} );
ok( scalar( grep { $_ eq 'description' } @{$missing} ),
    'a card with no description is missing one' );
ok( scalar( grep { $_ eq 'parent' } @{$missing} ),
    'and a card with no parent is missing that, which police never used to say' );
ok( scalar( grep { $_ eq 'checklist' } @{$missing} ),
    'and a card with no checklist, which police never used to say either' );

done_testing;

__END__

=head1 NAME

224-one-definition-of-a-complete-card.t - decided once, read twice

=head1 DESCRIPTION

Police and the push gate each carried a list of what a complete card is, and
they disagreed in both directions: the gate alone wanted a checklist and a
parent, police alone wanted a description. The same card at the same moment was
complete to one and incomplete to the other.

The engine owns the definition now. The gate is a separate program and cannot
share a variable, so it asks for the list rather than keeping one.

=cut
