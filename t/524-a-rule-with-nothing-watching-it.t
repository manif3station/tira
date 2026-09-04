#!/usr/bin/env perl
# A standing rule that only exists in a Telegram message.
#
# TKT-751. His instruction, Telegram 6104, 2026-08-29: "File a new ticket for
# refactor. Any Perl file more that 500 lines will be decomposed."
#
# Nothing enforces it, and the ground has been lost steadily since. The card was
# filed naming fourteen files. Measured again today there are EIGHTEEN, and the
# card's own list is wrong in both directions:
#
#   IT MISSES FIVE      lib/Tira/Job.pm (1263), lib/Tira/Tasklist.pm (792),
#                       lib/Tira/Attachment.pm (527), t/493 (600), t/86 (508)
#   IT COUNTS THREE     tools/prove-the-gate and tools/browser-tests are bash;
#   THAT ARE NOT PERL   tools/card-holes is python. His rule says PERL.
#
# lib/Tira/CLI/Browser.pm is the argument in one line: TKT-607's decomposition
# CREATED it, at 805 lines, three days before the card was filed. It is 1228
# now. The split that fixed one file produced another that breaks the rule, and
# then that one grew 348 lines, because nothing was watching the number.
#
# WHY THIS IS A TEST AND NOT A TOOL. tools/gate-run already refuses a release
# when the suite fails, so a size guard written as a .t file is enforced by every
# path that exists today. A script in tools/ needs somebody to remember to run
# it, which is the same as the rule we have now.
#
# WHY IT WALKS BY SHEBANG RATHER THAN BY THE CARD'S LIST. Naming files is how a
# guard misses the fifteenth, which is this card's own argument. And a guard
# built from the card's list would have refused three bash and python files on
# its first run - wrong in a way that teaches everybody to ignore it.
#
# WRITTEN RED: the exemption list is empty, so this fails naming all eighteen.

use strict;
use warnings;

use File::Find ();
use File::Spec;
use Test::More;

# Every Perl file that ships, found rather than listed.
#
# lib/ and t/ by extension; cli/ and tools/ by shebang, because a Perl script
# there has no extension to go by and a bash one must not be counted. The
# directories are named but the files inside them never are.
sub perl_files {
    my @found;
    for my $dir (qw(lib t cli tools)) {
        next if !-d $dir;
        File::Find::find(
            {   no_chdir => 1,
                wanted   => sub {
                    my $path = $File::Find::name;
                    return if !-f $path;
                    $path =~ s{\A\./}{};

                    return push @found, $path if $path =~ /\.(?:pm|t|pl)\z/;

                    # A shebang is the only honest way to tell a Perl script
                    # from a bash one when neither carries an extension. The
                    # card this test comes from got that wrong for three files.
                    open my $fh, '<', $path or return;
                    my $first = <$fh>;
                    close $fh;
                    push @found, $path
                      if defined $first && $first =~ /\A#!.*\bperl\b/;
                },
            },
            $dir,
        );
    }
    return sort @found;
}

# The counter reads into a LEXICAL, not into $_, and that is not style.
#
# The first version was `$lines++ while <$fh>`, which assigns each line to $_.
# Every caller here is inside a grep, where $_ is an ALIAS to the element of
# @files being tested - so counting a file's lines wrote that file's contents
# over the array entry, and left it undef at end-of-file. The result was
# eighteen undefs where eighteen paths should have been, eighteen
# uninitialized-value warnings, and a die on `open ''`. The assertion still
# failed, which is how it nearly passed for the wrong reason: the file was
# written red and a red result looked like the point.
sub line_count {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read '$path': $!";
    my $lines = 0;
    my $line;
    $lines++ while defined( $line = <$fh> );
    close $fh;
    return $lines;
}

my $LIMIT = 500;

# THE EXEMPTION LIST. A path to a REASON, never a bare path - his rule with an
# escape hatch that costs nothing is his rule deleted. Each reason says what the
# file is and names the card that owns splitting it, so the list reads as a
# decomposition backlog rather than as permission.
#
# NO LINE COUNTS IN THE REASONS, deliberately. A number written beside a file
# that is still growing is a number that goes stale, and this project has three
# instances of exactly that on the books this week. The note() at the foot of
# this file prints the live sizes, measured at the moment it runs.
#
# EVERY ENTRY IS A DEBT. TKT-751 is what identified them; TKT-746 already owns
# splitting lib/Tira.pm. The rest have no dedicated card yet, which is the next
# thing this list is for - it is now visible, and the guard below stops it
# growing while somebody works through it.
my %EXEMPT = (

    # The engine. Every record verb, every rule, the whole policy pass and the
    # question and tasklist machinery in one file - splitting it is its own
    # project, and it already has a card.
    'lib/Tira.pm' => 'the engine, and splitting it is its own project - TKT-746 owns it',

    # The command surface. TKT-607 took it from 6,048 lines by lifting the
    # record verbs out; what remains is the dispatch table and the option guard,
    # and the next lift needs a concern to lift rather than a line target.
    'lib/Tira/CLI.pm' => 'the dispatch index; TKT-607 halved it and the next cut '
      . 'needs a concern, not a line target - TKT-751 identified it',

    # These four grew past the limit after the decompositions that created them,
    # which is the argument this whole card makes. Browser.pm is the sharpest:
    # TKT-607 CREATED it at 805 lines, already over.
    'lib/Tira/CLI/Browser.pm' => 'created over the limit by TKT-607 and grown since '
      . '- the case that proves a split needs a guard - TKT-751 identified it',
    'lib/Tira/CLI/Police.pm' => 'the police pass and its bridge, grown with every '
      . 'rule added - TKT-751 identified it',
    'lib/Tira/CLI/Serve.pm' => 'the dashboard server and its police-beside-the-board '
      . 'supervision - TKT-751 identified it',
    'lib/Tira/Job.pm' => 'repeated jobs: schedules, command parsing and the words '
      . 'that describe them - TKT-751 identified it',

    'lib/Tira/Tasklist.pm'     => 'the whole tasklist, one concern already - TKT-751 identified it',
    'lib/Tira/DashboardWeb.pm' => 'the HTML dashboard view - TKT-751 identified it',
    'lib/Tira/Attachment.pm'   => 'content-addressed attachment storage - TKT-751 identified it',

    # The test files. A .t file is one story and splitting it usually means
    # telling half of it somewhere else, so these are the entries most likely to
    # be argued with - which is why each says what the file covers rather than
    # only that it is long.
    't/517-a-job-you-can-only-fix-from-a-terminal.t' =>
      'the job-management surface end to end - TKT-751 identified it',
    't/418-a-command-announced-and-thrown-away.t' =>
      'announcing a command before its proof, every path - TKT-751 identified it',
    't/493-a-monitor-that-died.t' =>
      'monitor liveness across platforms, Windows included - TKT-751 identified it',
    't/19-dashboard-dialog.t' =>
      'the dashboard dialog surface - TKT-751 identified it',
    't/419-a-queue-that-disagrees-with-the-board.t' =>
      'the tasklist and the board agreeing, every path - TKT-751 identified it',
    't/390-a-list-that-does-not-need-a-ticket.t' =>
      'tasklist reads without a card - TKT-751 identified it',
    't/519-two-terminals-to-watch-one-board.t' =>
      'police singleton and the dashboard holding it - TKT-751 identified it',
    't/86-police-end-to-end.t' =>
      'a full police pass, the oldest end-to-end test here - TKT-751 identified it',
    't/317-a-done-that-proved-nothing.t' =>
      'proof required to mark an item done - TKT-751 identified it',
);

my @files = perl_files();

# non-empty is the whole claim: a walk that found nothing would report every
# assertion below as satisfied, which is the exact shape of a guard that has
# stopped guarding.
cmp_ok( scalar @files, '>', 100,
    'the walk found the Perl files that ship - lib/ and t/ by extension, '
      . 'cli/ and tools/ by shebang' );

ok( ( grep { $_ eq 'lib/Tira.pm' } @files ),
    'and it found lib/Tira.pm, the largest of them - a walk that missed the '
      . 'worst offender would pass this file while proving nothing' );

ok( !( grep { $_ eq 'tools/prove-the-gate' } @files ),
    'and NOT tools/prove-the-gate, which is bash. The card names it as one of '
      . 'fourteen Perl files over the limit; it is not Perl, and a guard built '
      . 'from that list would refuse it on its first run' );

ok( !( grep { $_ eq 'tools/card-holes' } @files ),
    'nor tools/card-holes, which is python - the same mistake, and the reason '
      . 'this walks by shebang rather than by directory' );

ok( ( grep { $_ eq 'tools/coverage-holes' } @files ),
    'but tools/coverage-holes IS found, because it is Perl - so the shebang '
      . 'check includes as well as excludes, and is not just a way of skipping '
      . 'the tools directory' );

# --- the rule ----------------------------------------------------------------

my @over = grep { line_count($_) > $LIMIT } @files;
my @unexplained = grep { !exists $EXEMPT{$_} } @over;

is_deeply( \@unexplained, [],
    "EVERY PERL FILE OVER $LIMIT LINES IS SPLIT OR EXEMPTED WITH A REASON. "
      . 'His rule, Telegram 6104: any Perl file more than 500 lines will be '
      . 'decomposed. Nothing has enforced it, and the count has gone from '
      . 'fourteen to eighteen while the card sat in the backlog' )
  or diag( "over $LIMIT lines and not exempted:\n"
      . join( "\n", map { sprintf '  %6d  %s', line_count($_), $_ } @unexplained ) );

# --- the escape hatch costs something ----------------------------------------

# The three checks below are written as subs and then run TWICE: once against
# the real list, and once against a list built here to break each of them.
#
# Against the real list alone they would all pass while it is empty, and pass for
# the reason a test must never pass for - there being nothing to check. This file
# is written red, so an assertion that cannot fail today would sit in the green
# column beside a genuine failure and look like part of the proof.

sub bare_entries {
    my ($list) = @_;
    return [ grep { !defined $list->{$_} || $list->{$_} !~ /\S/ } sort keys %{$list} ];
}

sub cardless_entries {
    my ($list) = @_;
    return [ grep { ( $list->{$_} // '' ) !~ /\b(?:TKT|EPC|SOW)-\d+\b/ } sort keys %{$list} ];
}

sub stale_entries {
    my ($list) = @_;
    return [ grep { !-f $_ || line_count($_) <= $LIMIT } sort keys %{$list} ];
}

is_deeply( bare_entries( \%EXEMPT ), [],
    'A BARE PATH REFUSES RATHER THAN EXEMPTS. An exemption list anybody can '
      . 'add a path to is the rule deleted with extra steps, so a reason is '
      . 'the price of an entry - the same shape tools/gate-run already uses '
      . 'for coverage, which refuses a module "listed as exempt with no reason '
      . 'beside it"' );

is_deeply( cardless_entries( \%EXEMPT ), [],
    'and every reason names the card that owns splitting the file, so the list '
      . 'is a backlog somebody can work rather than a set of permanent '
      . 'exceptions' );

# Criterion 3 asks for the count to be reported so the list emptying is visible.
# A count nobody has to keep true is the thing this card is about, so entries are
# checked as well as counted: an exemption for a file that has been split, or
# deleted, or renamed, fails - which is what makes the number fall on its own
# rather than by somebody remembering to prune it.

is_deeply( stale_entries( \%EXEMPT ), [],
    'no exemption outlives the file it excused - one for a file that has been '
      . 'split, deleted or renamed fails, so the list shrinks by itself rather '
      . 'than by somebody remembering to prune it' )
  or diag( "exemptions no longer needed:\n"
      . join( "\n", map {"  $_"} @{ stale_entries( \%EXEMPT ) } ) );

# --- and each of those three has teeth ---------------------------------------

{
    my %broken = (
        'lib/Tira.pm'     => '',
        'lib/Tira/CLI.pm' => '   ',
    );
    is_deeply( bare_entries( \%broken ), [ 'lib/Tira.pm', 'lib/Tira/CLI.pm' ],
        'the bare-path check CATCHES one: an empty reason and a whitespace-only '
          . 'one are both refused, because a space is not a smaller reason than '
          . 'none' );

    is_deeply( bare_entries( { 'lib/Tira.pm' => 'huge, TKT-746 owns splitting it' } ), [],
        'and passes a real one, so it is not simply refusing everything' );
}

{
    my %broken = ( 'lib/Tira.pm' => 'it is very large and hard to split' );
    is_deeply( cardless_entries( \%broken ), ['lib/Tira.pm'],
        'the card-reference check CATCHES a reason that explains but tracks '
          . 'nothing - the difference between a backlog and an excuse' );

    is_deeply( cardless_entries( { 'lib/Tira.pm' => 'TKT-746 owns splitting it' } ), [],
        'and accepts one that names a card' );
}

{
    my %broken = (
        'lib/Tira/Toon.pm'          => 'under the limit, TKT-751',
        'lib/Tira/NoSuchModule.pm'  => 'does not exist, TKT-751',
    );
    is_deeply( stale_entries( \%broken ),
        [ 'lib/Tira/NoSuchModule.pm', 'lib/Tira/Toon.pm' ],
        'the stale check CATCHES both shapes - a file that is now under the '
          . 'limit and a path that is gone. Without this the list would keep '
          . 'entries for work already done, and the count would stop meaning '
          . 'anything' );

    is_deeply( stale_entries( { 'lib/Tira.pm' => 'still 14,420 lines, TKT-746' } ), [],
        'and leaves an exemption that is still needed alone' );
}

note(
    sprintf 'exemptions remaining: %d of %d Perl files (%d over %d lines)',
    scalar( keys %EXEMPT ), scalar @files, scalar @over, $LIMIT
);

done_testing();

__END__

=head1 NAME

524-a-rule-with-nothing-watching-it.t - the 500-line rule, enforced

=head1 WHY

TKT-751. Michael, Telegram 6104: "Any Perl file more that 500 lines will be
decomposed." Nothing enforced it, so the ground was lost quietly - the card was
filed naming fourteen files and there are eighteen, two of them test files
written after it was filed.

=head1 WHAT IS ASSERTED

That the walk finds the Perl files that ship, by extension under F<lib/> and
F<t/> and by B<shebang> under F<cli/> and F<tools/> - including
F<tools/coverage-holes>, which is Perl, and excluding F<tools/prove-the-gate>
and F<tools/card-holes>, which are bash and python and which the card wrongly
counts as offenders.

That every Perl file over 500 lines is either split or carries a written reason;
that a bare path refuses rather than exempts; that every reason names the card
which owns splitting that file; and that an exemption for a file which has since
been split, deleted or renamed fails, so the list can only shrink.

=head1 WHAT IS NOT ASSERTED

That any particular file has been split. Criterion 4 of the card says "either
split or in the list with a reason and a card reference" - the deliverable is
the guard and an honest list, not eighteen decompositions behind one commit.

=cut
