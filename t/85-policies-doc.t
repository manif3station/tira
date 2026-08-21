#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $doc = 'docs/POLICIES.md';
ok( -f $doc, 'the policies document exists' );

open my $fh, '<:raw', $doc or die "$doc: $!";
my $text = do { local $/; <$fh> };
close $fh;

# --- the disclaimer does real work ---------------------------------------

# A hundred examples read as a prescription unless the document says plainly
# that they are not one. Without this an agent copies the lot, the bridge buzzes
# constantly, and the whole channel gets ignored.
like( $text, qr/not a prescription/i, 'the document says the examples are not a prescription' );
like( $text, qr/raise a\s+ticket and ask/i,
    'and tells an agent to ask rather than guess when unsure' );
like( $text, qr/worse than no polic/i,
    'and warns that a policy without the bridge running looks like cover' );

# --- onboarding -----------------------------------------------------------

like( $text, qr/^## Onboarding/m, 'there is an onboarding section' );
like( $text, qr/d2 tira\.policy\.list/, 'which tells an agent how to see what exists' );
like( $text, qr/d2 tira\.column\.list/,
    'and to look at how the project actually works before declaring anything' );
like( $text, qr/d2 tira\.police\b/, 'and what the owner runs' );
like( $text, qr/d2 tira\.policy\.bridge/, 'and what the agent runs' );

# --- one hundred of them --------------------------------------------------

my @numbered = $text =~ /^\*\*(\d+)\.\*\* /mg;
ok( scalar @numbered >= 100, 'there are at least a hundred use cases' );
is_deeply( \@numbered, [ 1 .. scalar @numbered ],
    'numbered from one with none missing or repeated' );

# --- the heading's own number is a claim too -------------------------------
#
# The same shape TKT-413 fixed in SKILLS.md, found in this sibling document:
# a stated count never checked against the real one. Measured 2026-08-19: the
# heading read "One hundred use cases" while the document carried 107
# numbered examples - and worse than SKILLS.md's version of the bug, a
# leftover HTML comment repeating the same wrong number was not actually
# invisible. _policy_help in lib/Tira/CLI.pm returns this file raw, with no
# markdown rendering, so "d2 tira.policies" printed the comment as a literal
# line of output between worked examples 100 and 101. TKT-416.
my ($heading_claim) = $text =~ /^## (\d+) use cases$/m;
is( $heading_claim, scalar @numbered,
    'the use-cases heading names how many there really are' );
unlike( $text, qr/<!--/,
    'and no HTML comment leaks into a document that is read raw and printed verbatim' );

# --- every rule is shown at least once ------------------------------------

# A rule that exists but appears in no example is a rule nobody will use. A
# rule in an example that does not exist is a promise the tool does not keep.
# Both directions are checked, because either one alone would hide the other.
my %shown;
$shown{$1}++ while $text =~ /--rule\s+(\S+)/g;

# Everything a board can answer, not only what it can declare. card-damaged and
# card-unreadable are rules police raises and a board can put down or refuse,
# and they belong in this guide - but they are not declarable, so checking the
# document against the declarable catalogue alone called a real rule a broken
# promise. TKT-193.
my %real = map { $_ => 1 } @{ Tira::answerable_rules() };
my %declarable = map { $_ => 1 } @{ Tira::policy_rules() };

is_deeply( [ sort grep { !$real{$_} } keys %shown ], [],
    'every rule the document shows actually exists' );

# The other direction stays on the declarable set. A rule nobody can declare
# has no --rule example to show, and requiring one would make this ask for
# documentation that would be wrong.
is_deeply( [ sort grep { !$shown{$_} } keys %declarable ], [],
    'and every rule that exists is shown at least once' );

# Which leaves the two that are answerable and not declarable, checked by name
# rather than by counting - a rule that quietly stopped being answerable would
# otherwise pass this file in silence.
is_deeply( [ sort grep { !$declarable{$_} } @{ Tira::answerable_rules() } ],
    [ 'card-damaged', 'card-unreadable' ],
    'and the rules a board answers without declaring are exactly the two diagnostics' );

# --- the message parameters are real --------------------------------------

# Both directions again. A parameter documented but not implemented leaves a
# literal {placeholder} in somebody's message; one implemented but not
# documented is a feature nobody knows to use.
# Read from the parameter table only. The document also shows what a typo
# looks like, and treating that example as a promise would report a gap that
# is really the document doing its job.
my %documented_parameter;
for my $row ( $text =~ /^\|\s*(`\{\w+\}`(?:\s*\/\s*`\{\w+\}`)*)\s*\|/mg ) {
    $documented_parameter{$1}++ while $row =~ /`\{(\w+)\}`/g;
}
my %real_parameter = map { $_ => 1 } @{ Tira::policy_message_fields() };

is_deeply( [ sort grep { !$real_parameter{$_} } keys %documented_parameter ], [],
    'every message parameter the document offers actually exists' );
is_deeply( [ sort grep { !$documented_parameter{$_} } keys %real_parameter ], [],
    'and every one that exists is documented' );

# --- every command in it runs ---------------------------------------------

# The commands are run for real against a scratch project. A document full of
# examples that do not work is worse than no document: it teaches an agent that
# the surface is unreliable, and then it stops reading.
my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-11T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Documented', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, triage, planning, implement, doing, review, testing, verify, blocked, released, done'],
    sow_prefix => 'DCS', epic_prefix => 'DCE', ticket_prefix => 'DCT',
);

# The guide documents card-sandbox-missing, which refuses to be declared where
# no repository can be resolved - so a scratch board with no repository cannot
# run those examples. That refusal is the point of TKT-178 rather than an
# obstacle to it, so the scratch board is given one, which is what a board
# declaring that rule has to do anyway.
{
    my $repo = File::Spec->catdir( $root, 'repository' );
    mkdir $repo;
    mkdir File::Spec->catdir( $repo, '.git' );
    $tira->project_update( project => $root, repo => $repo );

    # A board that declares card-changed-by-owner must name its agent, the way
    # one that declares card-sandbox-missing must name its repository. TKT-376.
    $tira->project_update( project => $root, agent => 'claude' );
}

# A command may be written across several lines with a backslash, which is how
# anybody would write a long one - and how somebody would paste it. Reading
# only the first line tests a truncated command that nobody would ever run.
my $joined = $text;
$joined =~ s/\\\n\s*/ /g;
# Read the way a reader reads it: from the top, in order. A policy example may
# depend on something the document set two lines above - a work-in-progress
# limit belongs to the project now, so the example that declares the rule and
# leaves the number alone is only correct after the number has been set. Taking
# each policy line in isolation would report that example as broken when
# anybody following the document would find it works.
my @steps = $joined =~ /^(d2 tira\.(?:policy\.add|project\.limit) .+)$/mg;
my @commands = grep { /\Ad2 tira\.policy\.add / } @steps;
ok( scalar @commands >= scalar @numbered,
    'the document carries a command for every use case' );

my $ran = 0;
my $failed = 0;
for my $command (@steps) {
    if ( $command =~ /\Ad2 tira\.project\.limit\b/ ) {
        # With a number it is a setup step the examples below depend on;
        # without one it is the read-back, which changes nothing and is run
        # here anyway so a documented read that stopped working is caught.
        $command =~ /--max\s+(\d+)/
          ? $tira->project_limit( project => $root, max => $1 )
          : $tira->project_limit( project => $root );
        next;
    }
    my %args;
    my @tokens = $command =~ /--(\S+)\s+("[^"]*"|\S+)/g;
    while (@tokens) {
        my ( $flag, $value ) = ( shift @tokens, shift @tokens );
        $value =~ s/\A"|"\z//g;
        $flag =~ tr/-/_/;
        $flag = 'before' if $flag eq 'before_column';
        $args{$flag} = $value;
    }
    # A fresh board per example, because these are illustrations rather than a
    # script. The guide shows the same rule several times with different
    # settings - which is how a rule should be documented - and declaring one
    # twice on the same scope has been refused since TKT-339, so running them
    # all against one board made 40 of 79 collide with each other rather than
    # with anything wrong. The check is that each command is accepted as
    # written, and that is what this now asks.
    my $scratch = tempdir( CLEANUP => 1 );
    my $board = File::Spec->catdir( $scratch, 'board' );
    $tira->project_new(
        name => 'Guide', dir => $board, members => ['claude'],
        columns => ['backlog, triage, planning, implement, doing, review, testing, verify, blocked, released, done'],
        sow_prefix => 'GDS', epic_prefix => 'GDE',
        ticket_prefix => 'GDT',
    );

    # The same two things the shared board was given, for the same reasons:
    # card-sandbox-missing refuses where no repository can be resolved (TKT-178,
    # and that refusal is the point rather than an obstacle), and wip-limit
    # refuses without a limit somewhere. A board declaring either rule has to
    # do both anyway.
    my $repo = File::Spec->catdir( $board, 'repository' );
    mkdir $repo;
    mkdir File::Spec->catdir( $repo, '.git' );
    $tira->project_update( project => $board, repo => $repo );

    # A board that declares card-changed-by-owner must name its agent, the way
    # one that declares card-sandbox-missing must name its repository. TKT-376.
    $tira->project_update( project => $board, agent => 'claude' );
    $tira->project_limit( project => $board, max => 5 );

    my $ok = eval { $tira->policy_add( project => $board, %args ); 1 };
    if ( !$ok ) {
        $failed++;
        diag "did not run: $command\n  $@" if $failed <= 5;
        next;
    }
    $ran++;
}
is( $failed, 0, 'every command in the document is accepted exactly as written' );
ok( $ran >= 100, "and all $ran of them ran" );

done_testing;

__END__

=head1 NAME

85-policies-doc.t - the document an agent learns the surface from

=head1 DESCRIPTION

Every command in C<docs/POLICIES.md> is run for real against a scratch project.
A document full of examples that do not work is worse than no document: it
teaches an agent that the surface is unreliable, and an agent that believes
that stops reading the document at all.

The rules are checked in both directions. A rule that exists but appears in no
example is a rule nobody will find; a rule in an example that does not exist is
a promise the tool does not keep. Checking one direction alone would hide the
other.

The disclaimer is checked as carefully as the commands, because it is doing
real work. A hundred examples read as a prescription unless the document says
plainly that they are not one - and an agent that copies all hundred produces a
board that buzzes constantly, which is the one failure this whole subsystem
cannot survive.

=cut
