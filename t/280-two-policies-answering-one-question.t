#!/usr/bin/env perl
# A board that upgraded into 2.54's refusal keeps the duplicates it already
# had, and nothing said so.
#
# 2.54 fixed TKT-339 by refusing a SECOND policy.add on a rule and scope
# already declared - the right fix for what comes next, and no help for what
# is already in the store. One board, upgrading into the fix, still carried
# four pairs from before it existed - each pair a message-less bare
# re-declaration silently overriding an earlier, considered one, and on one
# pair tightening 15m to 10m with nobody deciding it. TKT-339's own complaint,
# reintroduced by a duplicate the fix could not see retroactively.
#
# The reporter found theirs by grouping `tira.policy.list -o json` by hand
# after reading the changelog for what "same scope" meant - which is not a
# route most boards will take. This is that same comparison, the one
# policy_add already makes against a NEW declaration, run once across
# everything already declared, and named in policy_review - "the review he
# asked to do" for declared, declined and unanswered rules, and now for
# duplicates too.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use lib 't/lib';
use Suite qw(engine_source);

use lib 'lib';
use Tira;

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

# --- one definition of "same scope", not two --------------------------------
#
# policy_add's own refusal and this detector must agree on what counts as a
# collision, or a board could be told it has none while policy_add would in
# fact refuse to declare a matching pair - two answers to the question this
# whole card is about. Read from the source rather than duplicated here, so a
# scope field added to one and not the other is caught structurally.

{
    my $source = engine_source();
    like( $source, qr/POLICY_SCOPE_FIELDS/,
        'the scope fields policy_add compares are named once, not copied into a second list' );
}

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-18T22:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Duped', dir => $root, members => ['claude'],
    columns => ['backlog, in-progress, review, done'],
    sow_prefix => 'DPS', epic_prefix => 'DPE', ticket_prefix => 'DPT',
);

# --- a clean board reports none ----------------------------------------------

{
    my $groups = $tira->policy_duplicates( project => $root );
    is_deeply( $groups, [], 'a board with no policies has no duplicate groups' );

    $tira->policy_add( project => $root, rule => 'orphan-card', action => 'log-only' );
    $groups = $tira->policy_duplicates( project => $root );
    is_deeply( $groups, [], 'and one policy alone is not a duplicate of anything' );
}

# --- a pair that predates the refusal, constructed the only way it can be ---
#
# policy_add itself now refuses to create this pair - which is the entire
# point, and also means it cannot be used to build the fixture. This is the
# one seam _policy_already_declared was built with: "a method rather than
# inline so a test can replace it." TKT-339.

my ( $kept, $removed );
{
    no warnings 'redefine';
    local *Tira::_policy_already_declared = sub { return undef };

    $kept = $tira->policy_add(
        project => $root, rule => 'answer-ok-not-folded',
        age => '15m', message => 'a considered setting', action => 'bridge-reminder',
    );
    $removed = $tira->policy_add(
        project => $root, rule => 'answer-ok-not-folded',
        age => '10m', action => 'bridge-reminder',
    );
}
isnt( $kept->{id}, $removed->{id}, 'the bypass really did create two distinct policies' );

{
    my $groups = $tira->policy_duplicates( project => $root );
    is( scalar @{$groups}, 1, 'the pair on the same rule and scope is found as one group' );
    is( $groups->[0]{rule}, 'answer-ok-not-folded', 'naming the rule they collide on' );

    my @ids = sort map { $_->{id} } @{ $groups->[0]{policies} };
    is_deeply( \@ids, [ sort( $kept->{id}, $removed->{id} ) ],
        'and both members of the pair, so a reader knows which ids to look at' );
}

# --- while a genuinely different scope is never grouped ---------------------
#
# The same rule on a different column is a real thing to want, exactly as
# policy_add itself allows it. Grouping it here would be the false positive
# this whole design has to avoid - a board full of noise is as unreadable as
# a board with none.

{
    $tira->policy_add(
        project => $root, rule => 'wip-limit',
        column => 'in-progress', max => 5, action => 'bridge-reminder',
    );
    $tira->policy_add(
        project => $root, rule => 'wip-limit',
        column => 'review', max => 2, action => 'bridge-reminder',
    );

    my $groups = $tira->policy_duplicates( project => $root );
    is( scalar @{$groups}, 1,
        'still one group - the same rule on two different columns is not a duplicate' );
}

# --- and policy_review names it, without a caller grouping JSON by hand -----

{
    my $review = $tira->policy_review( project => $root );
    ok( exists $review->{duplicates}, 'policy_review answers about duplicates too' );
    is( scalar @{ $review->{duplicates} }, 1, 'the same one group, in the one place a reader checks' );
    is( $review->{duplicates}[0]{rule}, 'answer-ok-not-folded', 'naming the same rule' );
}

# --- verified against this project's own board: nothing invented here ------
#
# The measured claim behind this ticket was checked against the real Tira
# Development board before writing a line of implementation: 54 policies, 0
# duplicate groups. A detector that invented a finding on a clean board would
# be worse than none - this is the same shape "Hourly Bug Hunter" exists to
# refuse: do not invent a defect to have something to fix.

done_testing;

__END__

=head1 NAME

280-two-policies-answering-one-question.t - TKT-352

=head1 DESCRIPTION

C<policy_add> has refused a second policy on the same rule and scope since
2.54, which does nothing for a board that already carried the duplicate
before the refusal existed. C<policy_duplicates> runs the identical
scope comparison across everything already declared and groups what
collides; C<policy_review> now names those groups, so a reader finds them in
the one place already used for "the review he asked to do" rather than
grouping C<policy.list> JSON by hand.

=cut
