#!/usr/bin/env perl
# TKT-587. docs/commands.md opens with "This is the reference: every command
# and argument, what it is for and when to use it." t/162 already proves the
# "every command" half. Nothing proved the "and argument" half - measured with
# a script rather than by eye (three earlier grep attempts on this project's
# own machine gave wrong answers, since 'grep' there is ugrep, which parses a
# flag like '--source' as its own option and silently reports nothing): of
# 211 option names bound in the shared parser's @spec array, 30 had no
# '--name' occurrence anywhere in docs/commands.md.
#
# Like t/162, this asks the reference itself rather than trusting that a
# command not named here fails the suite means an argument not named here
# would too - it would not, since the existing check is at the command
# level and never descends into a command's own arguments.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 't/lib';
use Suite qw(cli_source);

my $cli = cli_source('CLI.pm');

# --- the declaration table, read rather than assumed -------------------------
#
# Scoped to the @spec array GetOptionsFromArray parses, not the whole file -
# a wider read would also match %OPTION_READ_BY's and %MISLEADING_OPTIONS's
# own flag names in lib/Tira/CLI/Options.pm, which are cross-references to
# this table rather than declarations of their own.

my ($spec) = $cli =~ /my \@spec = \((.*?)\n    \);\n/s;
ok( defined $spec && length $spec, 'the @spec array was found to read' )
  or BAIL_OUT('cannot find my @spec = ( ... ); in lib/Tira/CLI.pm - has it moved or been renamed?');

my %declared;
while ( $spec =~ /'([a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)*)(?:[=:!][si\@]*)?'\s*=>/g ) {
    $declared{$_} = 1 for split /\|/, $1;
}
cmp_ok( scalar keys %declared, '>=', 100,
    'so there are options here to check - ' . scalar( keys %declared ) . ' found' );

# --- the reference, and what it deliberately leaves out -----------------------
#
# A short-form alias that never diverges in behaviour from the long form it
# stands for has nothing a second, separately-worded entry would say - '-o'
# for '--output' is the one declared option of this shape, and the reference
# already documents it, spelled as the short form throughout. Naming it here
# is the exception being visible rather than indistinguishable from an
# oversight, which is the whole point of keeping a list at all.
my %exception = ( o => 'single-letter alias for --output, documented as -o throughout' );

my $reference = do {
    local $/;
    open my $fh, '<:encoding(UTF-8)', 'docs/commands.md' or die "docs/commands.md: $!";
    <$fh>;
};

my @missing;
for my $flag ( sort keys %declared ) {
    next if exists $exception{$flag};
    push @missing, $flag if index( $reference, "--$flag" ) < 0;
}

is_deeply( \@missing, [],
    'every declared option is named in the command reference, or is a listed exception' );

# --- the guard is not vacuous -------------------------------------------------
#
# Doctoring the source the parser reads, the same way t/162's own command
# check is proved rather than assumed to fire - so this file cannot break the
# options it is checking.

{
    my $doctored_cli = $cli;
    $doctored_cli =~ s/(my \@spec = \()/$1\n        'zzz-undocumented-option=s' => \\\$option{zzz_undocumented_option},/;

    my ($doctored_spec) = $doctored_cli =~ /my \@spec = \((.*?)\n    \);\n/s;
    my %doctored_declared;
    while ( $doctored_spec =~ /'([a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)*)(?:[=:!][si\@]*)?'\s*=>/g ) {
        $doctored_declared{$_} = 1 for split /\|/, $1;
    }
    ok( $doctored_declared{'zzz-undocumented-option'},
        'the doctor actually added a new declared option, or this proves nothing' );

    my @doctored_missing = grep { !exists $exception{$_} && index( $reference, "--$_" ) < 0 }
      sort keys %doctored_declared;

    ok( ( grep { $_ eq 'zzz-undocumented-option' } @doctored_missing ),
        'a newly declared, undocumented option is caught' );

    # --- and naming it as a deliberate exception clears it -------------------

    my %doctored_exception = ( %exception, 'zzz-undocumented-option' => 'test fixture' );
    my @cleared_missing = grep { !exists $doctored_exception{$_} && index( $reference, "--$_" ) < 0 }
      sort keys %doctored_declared;
    is_deeply( \@cleared_missing, [],
        'and adding it to the exception list, with a reason, clears the guard' );
}

done_testing;

__END__

=head1 NAME

1079-an-argument-the-reference-forgot.t - the reference names every argument, or excepts it

=head1 DESCRIPTION

C<docs/commands.md> promises "every command and argument". C<t/162> proves the
command half; this proves the argument half against the shared parser's own
C<@spec> declaration table in F<lib/Tira/CLI.pm> - 211 option names at the
time this was written, 30 of which appeared nowhere in the reference.

C<-o>, the single-letter alias for C<--output>, is the one deliberate
exception: it never diverges in behaviour from the long form the reference
already documents throughout, so a second entry for it would say nothing new.
A future exception needs the same kind of reason recorded beside it, not a
bare name added to make the guard pass.

=cut
