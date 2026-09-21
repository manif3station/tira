#!/usr/bin/env perl

# --help must name the arguments the command refuses without.
#
# _usage() answers from SKILLS.md's own usage catalogue: it greps for a line
# beginning "tira.<command> " and prints what follows. A command with no line
# there falls back to "dashboard tira.<cmd> [options]", which names nothing.
#
# Two shapes, and the second is the dangerous one.
#
#   required-action.update, required-action.add, required-action.list and
#   question.ask have NO line, so --help says [options]. That at least signals
#   that something is being withheld.
#
#   checklist.update HAS a line, and it lists three optional flags while
#   omitting the two mandatory ones. It looks exhaustive. A caller has no
#   reason to doubt it.
#
# Reported independently from another board on 2026-08-27 with a cost attached:
# four checklist.update calls were written from --help, their output was
# suppressed, and the author walked away believing four entries were ticked
# while the checklist read 0/9. Caught only by the checklist-unmoved rule.
#
# The enforcement is not in question and is not being relaxed. Marking an entry
# done costs a --command/--proof pair (TKT-453), which is what stopped that
# author ticking an entry with nothing behind it. The fault is that --help does
# not say so.
#
# This file also holds the general guard, because the specific fix is one
# afternoon and the drift is for ever: every dispatchable command must have a
# usage line, so no command can quietly fall back to [options] again.

use strict;
use warnings;

use File::Spec;
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite qw(cli_source);
use Tira;
use Tira::CLI;
# Tira::CLI::Usage holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Usage;

# --- every dispatchable command has a usage line -----------------------------

# The whole command layer, walked, not lib/Tira/CLI.pm by name. TKT-837 lifted
# the option guard into lib/Tira/CLI/Options.pm and took five `$command eq
# '...'` literals with it, so a named read stopped seeing record.clone and
# record.update - and this test failed saying they "now have a usage line and
# should leave the ledger" when they had merely moved out of view. The ledger
# was right; the reading of it was not. Third test today to need this: t/239
# parsed the same tables by name, and t/237 localised a subroutine that had
# moved packages.
my $cli = cli_source();

# The first version of this guard read only the %method table and asserted
# "every dispatchable command has a usage line". It passed, and it was wrong:
# %method is one of three dispatch routes, and 49 commands answered by the
# earlier if/elsif branches - police, next, policy.*, login.*, backup.*,
# project.*, question.attach, question.voice among them - still printed a bare
# [options]. A guard that reads one route and speaks for the whole surface is
# the same shape as the checklist.update usage line this file exists about: it
# looks exhaustive, so nobody checks. Codex review caught it, 2026-08-27.
#
# TKT-1115, 2026-09-21: a THIRD route - $command =~ /\Aprefix\.(a|b|c)\z/
# regex-alternation dispatch - was still unread even after the second route
# (the %method table) joined the scan. tira.login.status was the named
# example: dispatched entirely through login_verbs' own regex match, it
# never appeared as a literal 'eq' comparison or a %method key, so it stayed
# invisible to this file's own ledger and kept answering a bare [options]
# indefinitely - a gap SKILLS.md had documented honestly since TKT-904
# rather than silently assumed closed.
#
# So the surface is all three routes, and the outstanding ones are named
# rather than quietly excluded. The list is a ledger, not an allowance:
# nothing may join it without this test failing, and it shrinks as the
# lines get written.
#
# Tested through _usage() rather than _skills_usage_line() because _usage is
# what --help actually prints - project.create has its line hard-coded there
# and no SKILLS.md entry, so the lower-level check called it undocumented.

my %command;
$command{$1} = 1 while $cli =~ /\$command\s+eq\s+'([a-z][a-z0-9.\-]*)'/g;
my ($table) = $cli =~ /my \%method\s*=\s*\((.*?)\n    \);/s;
ok( $table, 'found the dispatch table to read the command list from' );
$command{$1} = 1 while $table =~ /'([a-z][a-z0-9.\-]*)'\s*=>/g;

# TKT-1115. A THIRD dispatch shape neither of the two above sees:
# $command =~ /\Aprefix\.(a|b|c)\z/ or /\Aprefix\.(?:a|b|c)\z/, routing by
# the verb captured into $1 - login_verbs/policy_verbs (lib/Tira/CLI/
# Board.pm) and several blocks in lib/Tira/CLI.pm itself (question.*,
# notify.*, record.*, job.*) are this shape. tira.login.status was
# invisible to this file for exactly this reason, documented as a known
# gap in SKILLS.md since TKT-904 rather than silently assumed fixed.
#
# Codex review: lib/Tira/CLI/Command.pm's own POD quotes this exact regex
# as an illustrative example (C<$command =~ /\Alogin\.(register|check|
# status|logout)\z/>) - scanning $cli raw would match that comment too, so
# the two assertions below could stay green from documentation alone even
# with the real dispatch code deleted. Comments and POD are stripped from
# a scoped copy first, so only executable source can satisfy this scan.
( my $executable_cli = $cli ) =~ s/^=\w.*?^=cut\n?//msg;
$executable_cli =~ s/^\s*#.*$//mg;
my $regex_count = 0;
while ( $executable_cli =~ /\$command\s*=~\s*\/\\A([a-z][a-z0-9_]*)\\\.\((?:\?:)?([a-z0-9|_-]+)\)\\z\//g ) {
    my ( $prefix, $alternatives ) = ( $1, $2 );
    for my $verb ( split /\|/, $alternatives ) {
        $command{"$prefix.$verb"} = 1;
        $regex_count++;
    }
}
cmp_ok( $regex_count, '>', 0, 'the regex-alternation dispatch shape was found and read too' );
ok( $command{'login.status'}, 'and it specifically surfaced tira.login.status, the named example of this gap' );

# Codex review: this pattern is `prefix.(a|b|c)` specifically, not every
# regex-dispatch shape in the file - `dashboard(?:\.(?:sow|epic|ticket))?`
# (an outer optional suffix, no bare "dashboard" alternative inside the
# group) is a different shape this loop does not parse. Both of those
# commands already have real usage lines via the %method/literal-eq
# routes, so the ledger is not missing anything today - but the scan
# itself is one dispatch shape wider, not exhaustive of every shape that
# could exist. Documented rather than silently assumed complete, the same
# honesty this file's own history already asks of every other claim in it.

# The stripped copy proves its own point: the illustrative POD example
# alone must NOT be enough to pass the assertions above, or they would
# stay green even with the real dispatch code deleted.
{
    my ($pod_only) = $cli =~ /(package Tira::CLI::Command;.*?=cut)/s;
    ok( $pod_only && $pod_only =~ /login\\\.\(register/,
        'sanity: the POD example text really is present in the raw source, so stripping it is not a no-op' );
    ( my $pod_stripped = $pod_only ) =~ s/^=\w.*?^=cut\n?//msg;
    $pod_stripped =~ s/^\s*#.*$//mg;
    unlike( $pod_stripped, qr/login\\\.\(register/,
        'and comment/POD stripping actually removes it, so the scan above is reading real code' );
}

cmp_ok( scalar keys %command, '>', 100,
    'all three dispatch routes were read, not just the method table' );

# All 49 are written, TKT-630 - the ledger is empty on purpose, and stays
# that way: a command that falls back to a bare [options] now fails the
# first assertion below rather than joining a list here.
my %known_bare = map { $_ => 1 } qw();

my @bare = sort grep { Tira::CLI::Usage::_usage($_) =~ /\Q [options] \E/ } keys %command;
my @new_bare = grep { !$known_bare{$_} } @bare;
is_deeply( \@new_bare, [],
    'no command has newly fallen back to a bare [options] - a new one must arrive with its usage line' )
  or diag( "commands whose --help now names nothing:\n  " . join( "\n  ", @new_bare ) );

my %still_bare = map { $_ => 1 } @bare;
my @fixed = sort grep { !$still_bare{$_} } keys %known_bare;
is_deeply( \@fixed, [],
    'and the ledger holds only commands that really still lack one, so it cannot outlive the debt' )
  or diag( "these now have a usage line and should leave the ledger:\n  " . join( "\n  ", @fixed ) );

# --- and the type-scoped ones an agent uses to walk a card -------------------

for my $command (qw(question.ask question.mark question.answer)) {
    ok( defined Tira::CLI::Usage::_skills_usage_line($command),
        "$command has a usage line - it is used at every gate and its flags are not guessable" );
}

# --- the mandatory pair is named where it is mandatory ------------------------
#
# Both of these refuse --status done without at least one --command/--proof
# pair. A usage line that omits the pair describes a command that does not
# exist.

for my $command (qw(checklist.update required-action.update)) {
    my $line = Tira::CLI::Usage::_skills_usage_line($command) // '';
    like( $line, qr/--command/,
        "${command}'s usage line names --command, which it refuses done without" );
    like( $line, qr/--proof/,
        "${command}'s usage line names --proof, for the same reason" );
}

# --- a line that names them is not enough if it reads as optional -------------
#
# The pair is required together and repeatable FOR A DONE CLAIM. Written as two
# separate bracketed optionals it would be true about the parser and false about
# the command, which is the failure this whole file is about one level down.
#
# Since TKT-628 in 4.64 a --command is also usable alone, to record what is
# being run before it can be proved, so the line nests the proofs inside the
# commands rather than pairing them off: [--command TEXT ... [--proof TEXT ...]].
# That shape is a summary and not a grammar - the parser declares both as
# independent repeatable options and the engine pairs them by count afterwards -
# but it is the summary that misleads least, because a proof cannot arrive
# without a command and, once any proof is given, the counts must match.

for my $command (qw(checklist.update required-action.update)) {
    my $line = Tira::CLI::Usage::_skills_usage_line($command) // '';
    unlike( $line, qr/\[--command [A-Z]+\]/,
        "$command does not present --command as independently optional" );
}

done_testing();

__END__

=head1 NAME

t/410-help-that-hides-what-it-demands.t - a command's usage line must name the
arguments it refuses without

=head1 DESCRIPTION

C<_usage()> answers from SKILLS.md's usage catalogue and falls back to a bare
C<[options]> for any command with no line there. Three commands in the
required-action family and C<question.ask> had no line; C<checklist.update> had
one that listed three optional flags and omitted the two mandatory ones.

The second shape is worse than the first. C<[options]> admits it is withholding
something; an enumerated list that is missing the required arguments looks
complete, and a caller writes the wrong command with no reason to doubt it.
That happened on another board on 2026-08-27: four calls written from C<--help>,
output suppressed, four entries believed ticked while the checklist read 0/9.

The general assertion here is the part that lasts, and it is deliberately not
"every dispatchable command has a usage line" - 49 of them still do not, and a
test asserting otherwise would only be green because it read one of the two
dispatch routes. That was the first version of this file, and it is the exact
shape of the fault it was written about: an enumeration that looks complete.
What it asserts instead is that the set of commands whose C<--help> names
nothing matches a ledger written down here - so a new command cannot join it
silently, and a command that gains a usage line cannot be left in it. The
ledger shrinks; the guard does not need rewriting when it does.

The specific additions are an afternoon; the drift they came from is permanent
without something watching for it.

=cut
