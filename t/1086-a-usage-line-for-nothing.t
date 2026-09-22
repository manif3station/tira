#!/usr/bin/env perl
# TKT-660. Asking for --help about a command that does not exist answers as
# though it does: Tira::CLI->run(command => 'not.a.real.command', argv =>
# ['--help']) prints a fallback usage line - "Usage: dashboard
# tira.not.a.real.command [options] [-o toon|json|human]" - and returns
# success. That is the ONE moment an agent most wants to be told it has the
# name wrong, and instead gets what reads like confirmation.
#
# run()'s help branch (lib/Tira/CLI.pm) handles --help before dispatch, so
# the dispatcher's own "did you mean" for an unknown command is never
# reached. This proves the help branch itself now refuses an unknown bare
# command name, suggesting a near match the way the dispatcher and the
# unknown-option refusal both already do, while leaving help on every real
# command - including the 49 that print a bare [options] (TKT-630) -
# unchanged.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite qw(cli_source);
use Tira;
use Tira::CLI;
use Tira::CLI::Command;

sub help_for {
    my (@argv) = @_;
    my $out = '';
    my $status;
    {
        open my $capture, '>', \$out or die $!;
        local *STDOUT = $capture;
        my $err = '';
        open my $ecapture, '>', \$err or die $!;
        local *STDERR = $ecapture;
        $status = Tira::CLI->run( command => $argv[0], argv => [ '--help' ] );
        close $ecapture;
        $out .= $err;
    }
    return ( $out, $status );
}

# --- an invented command name is refused, not described --------------------

{
    my ( $out, $status ) = help_for('not.a.real.command');
    isnt( $status, 0, 'help for an invented command name fails rather than succeeding' );
    like( $out, qr/Unknown command/i, 'and says the command is unknown' );
    unlike( $out, qr/Usage: d2 tira\.not\.a\.real\.command/,
        'and does not print a usage line naming the invented command back' );
}

# --- a near-miss name suggests the real one ---------------------------------

{
    my ( $out, $status ) = help_for('checklist.ad');
    isnt( $status, 0, 'a near-miss of a real command still fails' );
    like( $out, qr/Did you mean/i, 'and offers a suggestion' );
    like( $out, qr/checklist\.add/, 'naming the real command it is close to' );
}

# --- more than one near-miss is sorted by distance --------------------------
#
# 'checklist.ad' above is close to exactly one real command, so the sort
# that ranks candidates never actually has two to compare. 'job.ad' is
# close to three (job.add, job.feed, job.run) - a case the single-candidate
# test above cannot exercise.

{
    my ( $out, $status ) = help_for('job.ad');
    isnt( $status, 0, 'a near-miss with several real candidates still fails' );
    like( $out, qr/Did you mean/i, 'and offers a suggestion' );
    like( $out, qr/job\.add/, 'naming the closest of the several candidates' );
}

# --- a real command with a usage line is unchanged --------------------------

{
    my ( $out, $status ) = help_for('checklist.add');
    is( $status, 0, 'help for a real, documented command still succeeds' );
    like( $out, qr/Usage: d2 tira\.checklist\.add/, 'and prints its real usage line' );
}

# --- a real command with NO usage line still prints the fallback -----------
#
# TKT-630's own ledger: these commands answer through the dispatcher but have
# no SKILLS.md line, so --help on them has always been a bare [options] - and
# this ticket does not change that, only what happens for a name with no
# entrypoint AT ALL.
#
# login.status itself was this example until TKT-1115 (5.173) gave it (and
# 8 siblings) a real usage line, closing the exact regex-dispatch gap TKT-1115
# found - so this now checks the SAME real command still succeeds and prints
# ITS real line, rather than the bare fallback it used to be the example of.

{
    my ( $out, $status ) = help_for('login.status');
    is( $status, 0, 'help for login.status still succeeds' );
    like( $out, qr/Usage: d2 tira\.login\.status \[-o FORMAT\]/,
        'and now prints its own real usage line (TKT-1115), not the bare [options] fallback it once did' );
}

# --- every command the dispatcher itself answers is known_command() too ----
#
# Codex review: the extraction is regex-over-source, which is inherently
# brittle to a reformat - proving it against a handful of hand-picked names
# above is not proof it covers the real surface. This walks the same two
# dispatch shapes t/410 already reads (a literal '$command eq' and the
# %method table) independently of Tira::CLI::Command's own extraction, and
# asserts every one of them is recognised - so a future change to either
# file's shape that this extraction stops understanding fails HERE, as a
# false negative that would refuse real --help calls, rather than only in
# a one-off manual sweep run once during implementation.

{
    my $source = cli_source('CLI.pm');

    my %command;
    $command{$1} = 1 while $source =~ /\$command\s+eq\s+'([a-z][a-z0-9_.\-]*)'/g;
    my ($table) = $source =~ /my \%method\s*=\s*\((.*?)\n    \);/s;
    $command{$1} = 1 while defined($table) && $table =~ /'([a-z][a-z0-9_.\-]*)'\s*=>/g;

    cmp_ok( scalar keys %command, '>', 100,
        'the dispatch surface has commands to check known_command() against' );

    my @unknown = sort grep { !Tira::CLI::Command::known_command($_) } keys %command;
    is_deeply( \@unknown, [],
        'every command the literal-eq/%method dispatch shapes name is recognised by known_command(), so none of them would be wrongly refused' )
      or diag( "these real commands would be refused as unknown:\n  " . join( "\n  ", @unknown ) );
}

# --- a $command =~ /PATTERN/ outside real dispatch is not mistaken for it --
#
# Codex review, second pass: the regex-extraction shape (added to answer the
# alternation-dispatch gap two tests above) is a plain source scan and does
# not know what a match is FOR. Two real false positives it found:
# lib/Tira/CLI.pm:783's `return $status if $command =~ /\Awarning\./;` is a
# post-dispatch banner guard, not dispatch, so 'warning.nonesuch' read as
# known and got the fallback usage line back - the exact bug this ticket
# exists to remove, reintroduced by a different code path. And this file's
# own POD, quoting its extraction technique as `$command =~ /PATTERN/`, was
# being scanned as a real dispatch regex too, so the literal string
# 'PATTERN' (and anything containing it, unanchored) read as a known
# command. Both fixed by stripping POD/comments before scanning, and by
# scoping lib/Tira/CLI.pm's scan to sub _invoke's own body, where every real
# dispatch shape in that file already lives.

{
    my ( $out, $status ) = help_for('warning.nonesuch');
    isnt( $status, 0, 'a name that only coincidentally matches a non-dispatch regex is still refused' );
    like( $out, qr/Unknown command/i, 'and reported unknown, not given the warning.* fallback usage line' );
}

ok( !Tira::CLI::Command::known_command('PATTERN'),
    "this module's own POD, which quotes its extraction technique as \$command =~ /PATTERN/, is not itself read as a dispatch regex" );

done_testing;

__END__

=head1 NAME

1086-a-usage-line-for-nothing.t - --help on a command that does not exist is refused, not described

=head1 DESCRIPTION

TKT-660. C<Tira::CLI-E<gt>run>'s help branch printed a fallback usage line
for ANY command name, including invented ones, because it returns before
the dispatcher's own unknown-command "did you mean" is ever reached. Proves
the help branch now refuses a name this skill does not answer, suggests a
near match the same way the dispatcher and the unknown-option refusal
already do, and leaves every real command's help - including the 49 that
still print a bare C<[options]> (TKT-630) - unchanged.

=cut
