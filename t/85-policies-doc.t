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

# --- every rule is shown at least once ------------------------------------

# A rule that exists but appears in no example is a rule nobody will use. A
# rule in an example that does not exist is a promise the tool does not keep.
# Both directions are checked, because either one alone would hide the other.
my %shown;
$shown{$1}++ while $text =~ /--rule\s+(\S+)/g;
my %real = map { $_ => 1 } @{ Tira::policy_rules() };

is_deeply( [ sort grep { !$real{$_} } keys %shown ], [],
    'every rule the document shows actually exists' );
is_deeply( [ sort grep { !$shown{$_} } keys %real ], [],
    'and every rule that exists is shown at least once' );

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
    name => 'Documented', dir => $root, members => ['michael'],
    columns => ['backlog, triage, planning, implement, doing, review, testing, verify, blocked, released, done'],
    sow_prefix => 'DCS', epic_prefix => 'DCE', ticket_prefix => 'DCT',
);

# A command may be written across several lines with a backslash, which is how
# anybody would write a long one - and how somebody would paste it. Reading
# only the first line tests a truncated command that nobody would ever run.
my $joined = $text;
$joined =~ s/\\\n\s*/ /g;
my @commands = $joined =~ /^(d2 tira\.policy\.add .+)$/mg;
ok( scalar @commands >= scalar @numbered,
    'the document carries a command for every use case' );

my $ran = 0;
my $failed = 0;
for my $command (@commands) {
    my %args;
    my @tokens = $command =~ /--(\S+)\s+("[^"]*"|\S+)/g;
    while (@tokens) {
        my ( $flag, $value ) = ( shift @tokens, shift @tokens );
        $value =~ s/\A"|"\z//g;
        $flag =~ tr/-/_/;
        $flag = 'before' if $flag eq 'before_column';
        $args{$flag} = $value;
    }
    my $ok = eval { $tira->policy_add( project => $root, %args ); 1 };
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
