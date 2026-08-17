#!/usr/bin/env perl
# An upgrade is traced until it is finished, not announced and forgotten.
#
# His words, after testing it by hand: "when i ask this question manually to all
# 4 agents. They all answered partially. Can this Upgrade be issued like other
# violation with reference and will trace the agent until they are are fully
# done?"
#
# And then, watching this agent do the same thing: "see! even yourself do that
# same." He was right. The upgrade notice reached this agent for 2.21, 2.33,
# 2.34 and 2.35 on 2026-08-16, and none of the three things it asks for was
# done until he asked directly - by which point checklist-unmoved had sat
# undeclared on this board all day.
#
# Every other thing police says carries a reference, escalates from NOTE to
# CRITICAL, and settles only when it stops being true. The one message that asks
# the agent to DO something had none of that: it was written once and gone.
#
# What is traced is the part that can be observed. "Has the agent read the
# changes" cannot be checked and a rule that settles on a promise is worse than
# no rule. What can be checked is the gap the reading is for: a rule that
# arrived with a new version and that this board has neither declared nor
# declined. tira.policy.undeclared already answers exactly that.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-16T23:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Traced', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'TRS', epic_prefix => 'TRE', ticket_prefix => 'TRT',
);

my $store = File::Spec->catdir( $tmp, 'police' );

sub reported {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'rules-undeclared' }
          @{ $pass->{violations} } ];
}

# --- the rule exists and is about the whole board -----------------------------

{
    my %rules = map { $_ => 1 } @{ Tira::policy_rules() };
    ok( $rules{'rules-undeclared'}, 'the catalogue offers a rule for this' );

    my $refused = !eval {
        $tira->policy_add( project => $root, rule => 'rules-undeclared',
            action => 'bridge-reminder', ref => 'TRT-001' );
        1;
    };
    ok( $refused, 'and it cannot be narrowed to one card, because it is about the board' );
    like( $@ // '', qr/whole board/,
        'saying so, rather than refusing for some other reason' );
}

$tira->policy_add( project => $root, rule => 'rules-undeclared',
    action => 'bridge-reminder' );

# --- a board with rules it has never answered ---------------------------------
#
# This board has just declared one rule out of the whole catalogue, so every
# other one is unanswered - which is the state a board is in after an upgrade
# brings rules it has never heard of.

{
    my $found = reported();
    is( scalar @{$found}, 1, 'a board with unanswered rules is reported' );

    # non-empty is the whole claim: a report with nothing in it would satisfy
    # any assertion about what it says.
    like( $found->[0]{detail} // '', qr/\S/, 'and says something about it' );
    like( $found->[0]{detail} // '', qr/\d+/,
        'naming how many are unanswered, so the reader knows the size of it' );
    like( $found->[0]{detail} // '', qr/tira\.policy\.undeclared/,
        'and the command that lists them' );
}

# --- it does not settle on a promise ------------------------------------------
#
# The half his question turns on. Answering some of them is what four agents
# did; the rule has to go on saying so.

{
    $tira->policy_add( project => $root, rule => 'orphan-card', action => 'log-only' );
    $tira->policy_add( project => $root, rule => 'card-unassigned', action => 'log-only' );

    my $found = reported();
    is( scalar @{$found}, 1,
        'answering some of them leaves it reported, which is the whole of his question' );
}

# --- and settles when every rule has an answer --------------------------------
#
# Declined counts. A board saying "not this one, and here is why" has answered
# it as surely as a board that declared it - the point is that nothing is left
# unconsidered.

{
    my %answered = map { ( $_->{rule} // '' ) => 1 }
      ( @{ $tira->policy_list( project => $root ) },
        @{ $tira->policy_declined( project => $root ) } );

    for my $rule ( @{ Tira::policy_rules() } ) {
        next if $answered{$rule};
        $tira->policy_decline( project => $root, rule => $rule, author => 'claude',
            reason => 'Not for this board: it is a fixture, and the rule was considered.' );
    }

    is_deeply( $tira->policy_undeclared( project => $root ), [],
        'every rule now has an answer, declared or declined' );
    is_deeply( reported(), [], 'and the rule settles' );
}

# --- proved by leaving one unanswered again ------------------------------------

{
    my ($undo) = grep { ( $_->{rule} // '' ) eq 'orphan-card' }
      @{ $tira->policy_list( project => $root ) };
    $tira->policy_remove( project => $root, id => $undo->{id} );

    my $found = reported();
    is( scalar @{$found}, 1,
        'one rule left unanswered brings it back, so the trace is on the state and not on a memory' );
}

done_testing;

__END__

=head1 NAME

247-an-upgrade-that-is-traced.t - a rule that follows an upgrade to the end

=head1 DESCRIPTION

The upgrade notice asked the agent to do three things and was then gone: no
reference, no escalation, nothing that noticed whether any of it happened. Four
agents asked by hand all answered partially, and this agent ignored it four
times in one day.

C<rules-undeclared> traces the observable half - a rule this board has neither
declared nor declined - with a reference and the escalation every other rule
has, and settles only when every rule has an answer. What cannot be observed is
not claimed: whether the changes were read is not something a rule can check,
and a rule that settles on a promise is worse than none.

=cut
