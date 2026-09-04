#!/usr/bin/env perl
# TKT-745. tira.police.outstanding takes --fresh, which runs a pass inline
# instead of reporting whatever the last pass wrote. SKILLS.md's entry for that
# command describes it at length - --by-rule, -o json, the TKT-291 grouping, the
# TKT-684 staleness paragraph - and never mentions --fresh.
#
# SKILLS.md calls itself the normative implemented interface, and it is what an
# agent is told to read. So the option that answers "is this answer stale, or is
# the board really clean" is invisible to the reader most likely to need it.
#
# THE COST IS ON THE BOARD. TKT-740 was filed saying "WORKAROUND MEANWHILE: none
# available to an agent", and TKT-744 an hour later saying "I do not know what
# drives a pass". Both were written by somebody reading SKILLS.md and
# docs/POLICIES.md, and both are answered by --fresh.
#
# WHAT IS ALREADY DONE, so this file does not ask for it twice: docs/POLICIES.md
# gained the who-runs-a-pass explanation with TKT-684's documentation, after this
# card was filed. Lines 19-25 there now name --fresh. docs/commands.md was always
# correct. The gap is SKILLS.md alone, plus the absence of anything that would
# have caught the drift.

use strict;
use warnings;

use Test::More;

use lib 't/lib';
use Suite ();
my $skills = do {
    local $/;
    open my $fh, '<:encoding(UTF-8)', 'SKILLS.md' or die "Cannot read SKILLS.md: $!";
    <$fh>;
};

# The entry is one long prose paragraph rather than a usage block, so it is
# found by the sentence that opens it and taken to the end of that line.
my ($entry) = $skills =~ /^(`dashboard tira\.police\.outstanding`[^\n]*)$/m;

# Guarded before anything is asserted about its contents. Without this, every
# "the entry mentions X" assertion below would fail for the wrong reason if the
# entry were renamed, and every "does not mention" assertion would pass on an
# empty string.
ok( defined $entry && length $entry,
    'SKILLS.md has a police.outstanding entry to check' )
  or BAIL_OUT('no police.outstanding entry found in SKILLS.md');

# --- THE CARD -----------------------------------------------------------------

like( $entry, qr/--fresh/,
    'SKILLS.md names --fresh in its police.outstanding entry - the option that '
      . 'answers whether the answer is stale, in the document an agent is told '
      . 'to read' );

# Naming it is not enough on its own: the entry has to say what it does, or a
# reader learns a flag exists and still cannot tell whether to use it.
like( $entry, qr/--fresh[^\n]{0,400}?\bpass\b/,
    'and says that it runs a pass, rather than only listing the flag' );

# --- THE GUARD ----------------------------------------------------------------
#
# The drift this card is about is that an option was added and the normative
# document was not. A test that only asserts --fresh is present fixes today and
# not tomorrow, so the options the command accepts and the options SKILLS.md
# names are reconciled here.

my $cli = Suite::cli_source();

# The three options this command accepts and a reader would act on. Taken from
# the binding table rather than from memory, and asserted to still be bound - a
# renamed flag must fail here rather than quietly shrink the list being checked.
#
# READ BY NAME, and this one has to be. The half below asks whether THE MODULE
# THAT IMPLEMENTS police.outstanding consumes the option, which is a claim
# about which file the code is in - asked of the whole command surface it would
# be satisfied by any command anywhere reading $option->{fresh}, which is
# exactly the confusion the two halves exist to prevent. So the path stays and
# says why, while the half above uses the walker: the shared option table has
# already moved once, on TKT-837. TKT-921.
#
# t/486 marker: about this file, not its code
my $police = do {
    local $/;
    open my $fh, '<:encoding(UTF-8)', 'lib/Tira/CLI/Police.pm'
      or die "Cannot read Police.pm: $!";
    <$fh>;
};

my @accepted = qw(by-rule fresh);
for my $flag (@accepted) {
    ( my $key = $flag ) =~ tr/-/_/;

    # Two halves, because the option table in CLI.pm is shared by every command.
    # Finding a flag bound there proves the parser accepts the spelling, not
    # that this command is the one that reads it - so the second half looks for
    # the option being consumed in the module that implements police.outstanding.
    like( $cli, qr/'\Q$flag\E(?:=[si])?'\s*=>/,
        "--$flag is bound in the command surface's option table" );
    like( $police, qr/\$option->\{\Q$key\E\}/,
        "and lib/Tira/CLI/Police.pm actually reads \$option->{$key}, so it is an "
          . 'option of this command rather than one the shared parser happens to accept' );

    like( $entry, qr/--\Q$flag\E/,
        "and SKILLS.md's police.outstanding entry names --$flag" );
}

like( $entry, qr/-o json/,
    "and names -o json, the third thing the entry has always documented" );

done_testing();

__END__

=head1 NAME

t/439-an-option-the-normative-document-never-mentions.t - SKILLS.md must name the
options C<tira.police.outstanding> accepts

=head1 DESCRIPTION

C<--fresh> runs a police pass inline instead of reporting what the last pass
wrote. It is bound in F<lib/Tira/CLI.pm> and documented in F<docs/commands.md>,
and F<SKILLS.md> - which calls itself the normative implemented interface, and
which is the document an agent reads first - describes the command at length
without mentioning it.

Two cards were filed by somebody who could not find it: TKT-740, ending
"WORKAROUND MEANWHILE: none available to an agent", and TKT-744, "I do not know
what drives a pass".

=head2 Why the guard is half of this file

Asserting that C<--fresh> appears fixes the instance. The fault is that an option
can be added without the normative document following, and nothing notices. So
the accepted options and the documented ones are reconciled against each other,
and each accepted flag is first asserted to be genuinely bound - otherwise a
renamed flag would silently shrink the list this test checks and the file would
keep passing while proving less.

=head2 What this file deliberately does not ask for

F<docs/POLICIES.md> already explains which commands run a pass and which only
read, delivered with TKT-684 after TKT-745 was written, and F<docs/commands.md>
was always correct. Neither is re-litigated here.

=cut
