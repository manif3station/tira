#!/usr/bin/env perl
# Every way the push gate can refuse is either proved or accounted for.
#
# tools/prove-the-gate breaks the gate one check at a time, because a check
# that has never been seen to fail is not a check, it is a hope. The gate has
# seventeen ways to refuse and the tool exercised thirteen. The four it did not
# were not a decision - nobody had counted, and I miscounted them twice while
# raising the card, both times in the tool's favour, by reading for a pattern
# instead of reading the file.
#
# The one that mattered: the browser step was proved to refuse when the runner
# was ABSENT and never when a browser test RAN AND FAILED. Those are different
# refusals, and the second is the one that happened - ten browser tests passed
# on the release that broke the served dashboard.
#
# So the count is made here instead of by hand. The hook is read for the ways
# it can refuse, and the tool has to say, for each one, what proves it or why
# nothing can. Two of them cannot be provoked without damaging the machine the
# gate runs on, which is a decision worth writing down and not a gap to close.
#
# What this guard is not: it reads what the tool declares, so it catches the
# gate growing a refusal nobody covered, and a probe being deleted from under a
# declaration. It cannot tell that a probe proves the refusal it claims - only
# running it does that, which is the tool's own job.

use strict;
use warnings;

use Test::More;

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

my $hook   = slurp('tools/hooks/pre-push');
my $prover = slurp('tools/prove-the-gate');

# --- what the hook can refuse ----------------------------------------------
#
# Read from the hook rather than listed here, because a list written here is a
# second copy of the thing being counted and would drift the moment the gate
# grows a step - which is exactly how the browser refusal went uncovered.

my @refusals;
for my $line ( split /\n/, $hook ) {
    next if $line =~ /\A\s*#/;
    my ($quote) = $line =~ /\bfail\s+(["'])/ or next;
    my ($message) = $line =~ /\bfail\s+$quote([^$quote]*)/;

    # The message as far as its first interpolation or colon: what the gate
    # fills in is the file or the module, and the part before it is the reason.
    $message =~ s/[\$:].*\z//;
    $message =~ s/\s+\z//;
    push @refusals, $message if length $message;
}

# non-empty is the whole claim: a precondition for everything below, which
# would all pass against a hook this could not read at all.
#
# The floor was 15 against a hook with 17 refusals. TKT-680 removed the suite
# and coverage block and six refusals went with it, leaving 11 - so the floor
# is 9, keeping the same margin of two. The number is a parse guard and not a
# target: it says the file was read and yielded refusals, and lowering it here
# is the honest response to the hook genuinely having fewer, not a threshold
# being relaxed to accommodate a failure.
cmp_ok( scalar @refusals, '>=', 9,
    'the hook has ways to refuse, and they can be read out of it' );

# --- and what the tool says about each --------------------------------------
#
# One line per refusal in the tool, naming the refusal and then either the
# probe that breaks it or the reason nothing does.

my %covered;
for my $line ( split /\n/, $prover ) {
    my ( $what, $how ) = $line =~ /\A#\s*covers:\s*(.+?)\s*\|\s*(.+?)\s*\z/ or next;
    $covered{$what} = $how;
}

my @unaccounted = grep { !exists $covered{$_} } @refusals;
is_deeply( \@unaccounted, [],
    'and the tool says what proves each of them, or why nothing can' );

my %is_refusal = map { $_ => 1 } @refusals;
my @stale = grep { !$is_refusal{$_} } sort keys %covered;
is_deeply( \@stale, [],
    'and claims nothing about a refusal the hook no longer makes' );

# --- a claim that names something -------------------------------------------
#
# Either the words the probe prints about itself, or the reason nothing proves
# it. The words are what the probe is made of rather than a name given to it
# here, so deleting the probe deletes them and the declaration is left naming
# nothing - which is the failure this half catches. Read in code rather than in
# comments, so the tool's own explanation of a probe does not stand in for the
# probe.

my $code = join "\n", grep { !/\A\s*#/ } split /\n/, $prover;

my ( @nameless, @absent );
for my $what ( sort keys %covered ) {
    my $how = $covered{$what};

    if ( $how =~ /\Anot proved\b/ ) {
        push @nameless, $what if $how !~ /\Anot proved[:,]\s+(?:\S+\s+){4}\S+/;
        next;
    }

    push @absent, "$what -> $how" if index( $code, $how ) < 0;
}

is_deeply( \@nameless, [],
    'a refusal nothing proves carries a reason, not the words on their own' );
is_deeply( \@absent, [],
    'and every refusal said to be proved names something the tool still has' );

# --- the tool does not report success for a probe that never ran -------------
#
# Every step after the card check is unreachable while a card on the board is
# incomplete: the hook refuses at the cards and the probe never reaches what it
# was measuring. The tool learned to say so rather than report NOT PROVED for a
# reason that has nothing to do with the step - and then counted those as
# neither proved nor failed, so its closing line read "13 proved, 0 not proved"
# about a run that measured nothing. A silent skip in a tool whose whole
# purpose is proving is the fault it exists to catch.

like( $prover, qr/\$\{?not_measured\}?|not_measured=/,
    'a probe that could not run is counted' );
like( $prover, qr/not measured/,
    'and the closing count says so rather than reporting them as proved' );

done_testing;

__END__

=head1 NAME

233-what-the-gate-can-refuse.t - the gate's refusals against the tool's proofs

=head1 DESCRIPTION

C<tools/hooks/pre-push> has seventeen ways to refuse a push.
C<tools/prove-the-gate> exercised thirteen, and the four it missed were an
oversight rather than a decision - including the one that mattered, a browser
test that runs and fails, as opposed to a runner that is absent.

The count is made from the hook itself, so a gate that grows a step is not
covered by an old list. Each refusal is answered in the tool by the probe that
breaks it or by the reason nothing can: two of them cannot be provoked without
damaging the machine the gate runs on, which is a decision written down rather
than a gap.

This reads what the tool declares. It catches a refusal nobody covered and a
probe deleted from under its declaration; it cannot tell that a probe proves
what it claims, which is what running the tool is for.

=cut
