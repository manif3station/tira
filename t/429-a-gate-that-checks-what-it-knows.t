#!/usr/bin/env perl
# The coverage gate has to check what is in lib/, not what somebody typed.
#
# tools/gate-run holds the module list twice - once as -select arguments to
# cover, and once as the for-loop that reads the result - and both are literal:
#
#   -select lib/Tira.pm -select lib/Tira/CLI.pm -select lib/Tira/DashboardWeb.pm
#   for module in 'lib/Tira.pm' 'lib/Tira/CLI.pm' 'lib/Tira/DashboardWeb.pm'; do
#
# lib/Tira/OnboardWeb.pm is in neither. It has no coverage requirement at all,
# and the gate passes because the loop only visits the three it knows - it
# fails open, and silently, which is the worst way for a gate to be wrong.
#
# THE LIST IS DERIVED FROM THE FILESYSTEM HERE, WHICH IS THE POINT. A test that
# named the four modules would have to be maintained by exactly the discipline
# that let the gate fall behind - somebody remembering. This walks lib/ and
# requires every .pm it finds to be either gated or explicitly exempt, so a
# module added tomorrow is covered by this assertion the moment it exists,
# without anybody editing anything.
#
# The exemption half matters as much as the enumeration. A module that should
# not be held to 100% is a legitimate thing; a module that is not held to 100%
# because nobody updated a for-loop is not. The difference is whether a reason
# was written down, so this file requires the reason and not merely the
# exemption.

use strict;
use warnings;

use File::Find ();
use Test::More;

my $gate = do {
    open my $fh, '<', 'tools/gate-run' or die "tools/gate-run: $!";
    local $/;
    <$fh>;
};

# Established before anything is asserted about it. A claim about a file that
# failed to load is true for the wrong reason - t/147's subject, and the thing
# that made t/417 fail loudly rather than quietly tonight.
ok( $gate, 'tools/gate-run was read - ' . length($gate) . ' bytes' );

my @modules;
File::Find::find(
    { no_chdir => 1, wanted => sub { push @modules, $File::Find::name if /\.pm\z/ } },
    'lib' );
@modules = sort @modules;
cmp_ok( scalar @modules, '>=', 4,
    'lib/ holds the modules this gate is about - ' . join( ', ', @modules ) );

# --- every module is accounted for ------------------------------------------
#
# Asked of what the gate would SELECT, not of what its text contains. The first
# version of this searched the script for each module path, which was wrong in
# both directions once the list was derived: every path vanished from the file,
# so three modules "failed" while being correctly covered, and OnboardWeb.pm
# "passed" because a COMMENT mentioned it. A test satisfiable by prose is not a
# test.
#
# So the enumeration the gate uses is run here, and its output compared with
# what is actually on disk. One assertion per module, so a failure names the
# module nobody is checking.

# Matched on the enumeration command itself rather than on the loop syntax
# around it. The first version looked for `for module in $(find lib ...)`, and
# broke the moment the loop became an array read - it was pinned to a shape
# rather than to the thing that decides which modules are gated.
my ($finder) = $gate =~ /(find lib -name\s+["']\*\.pm["'][^)\n]*)/;
ok( $finder, 'the gate enumerates its modules with a command - ' . ( $finder // 'none' ) );

my @selected = $finder ? split /\n/, `$finder` : ();
chomp @selected;
@selected = sort grep { length } @selected;

my ($exempt_block) = $gate =~ /EXEMPT_COVERAGE=\(([^)]*)\)/s;
$exempt_block //= '';

for my $module (@modules) {
    my $covered = grep { $_ eq $module } @selected;
    my $exempt  = index( $exempt_block, $module ) >= 0 ? 1 : 0;
    ok( $covered || $exempt,
        "$module is selected by the gate's own enumeration, or exempted by it" );
}

# --- and it must DERIVE the list, not lengthen it -----------------------------
#
# The assertions above would all go green if somebody simply added
# OnboardWeb.pm to the two literal lists, and that is the fix this card
# explicitly does not want: the next module would be ungated exactly as this
# one was. So the hand-written form has to be gone, and an enumeration of lib/
# has to be there in its place.

unlike( $gate, qr/for module in\s+'lib\/[^']+'\s+'lib\//,
    'the gate no longer carries a hand-written list of module paths to loop '
      . 'over - lengthening that list would leave the next module ungated the '
      . 'same way' );
like( $gate, qr/find\s+lib\b|lib\/\*\*|\*\.pm/,
    'and it enumerates lib/ instead, so a module is gated by existing rather '
      . 'than by being remembered' );

# --- and an exemption has to carry its reason --------------------------------
#
# Declared: an empty exemption list is what passes here, and that is the right
# answer rather than an accident - nothing is exempt today. What must never
# pass is a module sitting in the list with no reason beside it, which is the
# same silence the hand-written list already had.

my ($exemptions) = $gate =~ /EXEMPT_COVERAGE=\(([^)]*)\)/s;
$exemptions //= '';
my @unreasoned = grep { $_ && $_ !~ /#/ } split /\n/, $exemptions;
is_deeply( \@unreasoned, [],
    'every coverage exemption carries a reason beside it - unreasoned: '
      . ( join ', ', @unreasoned ) );

# --- and the gate says what it checked ---------------------------------------
#
# A gate that checks a subset in silence is what this card is about. One that
# announces its subset can be read and disagreed with.

like( $gate, qr/checked coverage for/i,
    'the gate reports which modules it checked, so its guarantee is legible '
      . 'rather than assumed' );

done_testing();

__END__

=head1 NAME

t/429-a-gate-that-checks-what-it-knows.t - the coverage gate must hold every
module in lib/, not a list somebody typed

=head1 DESCRIPTION

C<tools/gate-run> names three module paths, twice - once as C<-select>
arguments and once in the loop that reads the result. C<lib/Tira/OnboardWeb.pm>
is in neither, so it has no coverage requirement, and the gate passes because
the loop only visits the modules it knows. It fails open and says nothing.

This file derives the list from the filesystem instead. A test that named the
four modules would need maintaining by the same discipline that let the gate
fall behind, so it walks C<lib/> and requires every C<.pm> to be gated or
explicitly exempt - a module added tomorrow is covered from the moment it
exists.

The exemption half is deliberate. A module that should not be held to 100% is
legitimate; one that is not held to 100% because nobody updated a for-loop is
not. The difference is a written reason, so an exemption without one fails here.

The last assertion asks the gate to say which modules it checked. A gate that
checks a subset silently is the fault this card exists for; one that announces
its subset can be read, and disagreed with.

=cut
