#!/usr/bin/env perl
# Declaring a rule that is already declared is refused, not silently doubled.
#
# Reported by zen-framework, and what makes it worth a card is what it cost
# them rather than the duplicate itself. wip-limit was declared at max 5. The
# owner decided it should be 9, so they ran policy.add again with --max 9. It
# returned success and created a second policy; the first was untouched and
# still active; both then covered the same rule and the same column with
# different maxima, and the stricter one kept firing.
#
# So they told the owner his decision was applied, and minutes later the same
# finding escalated to URGENT again. They found it by going back to ask why -
# not because anything reported a conflict.
#
# The mechanism was fine: policy.remove on the old id settled it immediately.
# What was missing is any signal that adding one had not replaced the other.
#
# Refused rather than replaced, which is this codebase's answer to the same
# shape elsewhere: a command that quietly does something other than what the
# caller meant is worse than one that stops and names the thing in the way.
# Replacing would also silently discard a policy somebody may have wanted.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-17T21:20:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Declared', dir => $root, members => ['claude'],
    columns => ['backlog, in-progress, review, done'],
    sow_prefix => 'DCS', epic_prefix => 'DCE', ticket_prefix => 'DCT',
);

# --- the first declaration -------------------------------------------------------

my $first = $tira->policy_add( project => $root, rule => 'wip-limit',
    column => 'in-progress', max => 5, action => 'bridge-reminder' );
ok( $first->{id}, 'a rule can be declared' );

# --- and the same rule on the same column again ----------------------------------
#
# Their exact sequence: the same rule, the same column, a different limit,
# meaning "change it" and getting "and also this".

{
    my $again = eval {
        $tira->policy_add( project => $root, rule => 'wip-limit',
            column => 'in-progress', max => 9, action => 'bridge-reminder' );
    };
    my $why = $@ // '';

    ok( !$again, 'declaring it a second time on the same column is refused' );
    like( $why, qr/\Q$first->{id}\E/, 'naming the policy already there' );
    like( $why, qr/policy\.remove|policy\.update/,
        'and what to run to change it, rather than leaving the caller to guess' );

    my @live = grep { ( $_->{rule} // '' ) eq 'wip-limit' }
      @{ $tira->policy_list( project => $root ) };
    is( scalar @live, 1, 'and only the first one exists, so nothing was doubled' );
    is( $live[0]{max}, 5,
        'still at the limit it was declared with - the refusal changed nothing' );
}

# --- while a genuinely different scope is still allowed ---------------------------
#
# The same rule on another column is a real thing to want, and this must not
# become a rule that can only be declared once.

{
    my $other = eval {
        $tira->policy_add( project => $root, rule => 'wip-limit',
            column => 'review', max => 2, action => 'bridge-reminder' );
    };
    ok( $other, 'the same rule on a different column is allowed' ) or diag $@;

    my $narrower = eval {
        $tira->policy_add( project => $root, rule => 'wip-limit',
            column => 'in-progress', ref => 'DCT-001', max => 1,
            action => 'bridge-reminder' );
    };
    ok( $narrower, 'and the same rule and column narrowed to one card is allowed' )
      or diag $@;

    my @live = grep { ( $_->{rule} // '' ) eq 'wip-limit' }
      @{ $tira->policy_list( project => $root ) };
    is( scalar @live, 3, 'three policies, each covering something different' );
}

# --- and a board-wide rule declared twice is refused too ---------------------------
#
# Not every rule takes a column. The one that bit this project is orphan-card,
# declared board-wide twice on its own board.

{
    my $once = $tira->policy_add( project => $root, rule => 'orphan-card',
        action => 'log-only' );

    # The identical declaration again is a no-op, not an error, and that is
    # right: nothing is ambiguous about asking for what is already true. This
    # assertion asked for a refusal on the first draft and was wrong - the
    # fault reported is two policies that DISAGREE, not two that agree.
    my $identical = $tira->policy_add( project => $root, rule => 'orphan-card',
        action => 'log-only' );
    is( $identical->{id}, $once->{id},
        'declaring exactly the same thing again returns the policy already there' );

    # Changing its action is the reported shape, board-wide rather than on a
    # column: the caller means "make it louder" and would otherwise get a
    # second policy with the quieter one still live.
    my $louder = eval {
        $tira->policy_add( project => $root, rule => 'orphan-card',
            action => 'bridge-reminder' );
    };
    ok( !$louder, 'while changing its action is refused rather than doubled' );
    like( $@ // '', qr/\Q$once->{id}\E/, 'naming the one already declared' );

    my @live = grep { ( $_->{rule} // '' ) eq 'orphan-card' }
      @{ $tira->policy_list( project => $root ) };
    is( scalar @live, 1, 'and the board carries one, still at the action it had' );
    is( $live[0]{action}, 'log-only', 'unchanged, because the refusal changed nothing' );
}

# --- and two policies watching different things are not a duplicate ------------
#
# Caught against live data before this shipped, which is the only reason it is
# right. An earlier draft treated the column as scope and the pattern as a
# setting, and would have refused two of the three leftover-process policies on
# this project's own board - they watch prove-the-gate, "until timeout" and
# projects-skills, all declared board-wide, every one of them meant.
#
# What a policy WATCHES is its scope, however the field lists are arranged.
# Only age, read_age, max and message say how strictly, and those are the ones
# that make two declarations two answers to one question.

{
    my $watched = File::Spec->catdir( $tmp, 'watched' );
    $tira->project_new(
        name => 'Watched', dir => $watched, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'WCS', epic_prefix => 'WCE', ticket_prefix => 'WCT',
    );

    my $first = $tira->policy_add( project => $watched, rule => 'leftover-process',
        action => 'bridge-reminder', age => '2h', pattern => 'prove-the-gate' );
    ok( $first, 'a rule that watches a named thing can be declared' );

    my $second = eval {
        $tira->policy_add( project => $watched, rule => 'leftover-process',
            action => 'bridge-reminder', age => '30m', pattern => 'until timeout' );
    };
    ok( $second, 'and again for a different thing, which is not a duplicate' )
      or diag $@;

    my $third = eval {
        $tira->policy_add( project => $watched, rule => 'leftover-process',
            action => 'bridge-reminder', age => '2h', pattern => 'projects-skills' );
    };
    ok( $third, 'and a third, exactly as this project has on its own board' ) or diag $@;

    # While the same pattern with a different age is the reported fault again.
    my $clash = eval {
        $tira->policy_add( project => $watched, rule => 'leftover-process',
            action => 'bridge-reminder', age => '10m', pattern => 'prove-the-gate' );
    };
    ok( !$clash,
        'while the same thing watched twice with different ages is refused' );

    my @live = grep { ( $_->{rule} // '' ) eq 'leftover-process' }
      @{ $tira->policy_list( project => $watched ) };
    is( scalar @live, 3, 'three policies, one per thing watched' );
}

# --- proved by allowing it again ---------------------------------------------------

{
    no warnings 'redefine';
    local *Tira::_policy_already_declared = sub { return };

    my $doubled = eval {
        $tira->policy_add( project => $root, rule => 'wip-limit',
            column => 'in-progress', max => 9, action => 'bridge-reminder' );
    };
    ok( $doubled, 'without the check the second declaration succeeds' );

    my @live = grep { ( $_->{rule} // '' ) eq 'wip-limit' }
      @{ $tira->policy_list( project => $root ) };
    is( scalar @live, 4,
        'and the board carries two policies for one column, which is what was reported' );
}

done_testing;

__END__

=head1 NAME

262-a-policy-declared-twice.t - a rule declared again, refused rather than doubled

=head1 DESCRIPTION

C<policy.add> on a rule and scope already declared created a second policy and
left the first active. The stricter one kept firing, so a limit somebody had
just changed went on enforcing the old value - and the agent reported the change
as applied.

It is refused now, naming the policy already there and what to run to change it.
A different column, or a narrowing to one card, is still a different scope and
still allowed.

=cut
