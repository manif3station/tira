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
use Tira;
use Tira::CLI;

# --- every dispatchable command has a usage line -----------------------------

my $cli = do {
    local $/;
    open my $fh, '<:encoding(UTF-8)', File::Spec->catfile( 'lib', 'Tira', 'CLI.pm' )
      or die "cannot read lib/Tira/CLI.pm: $!";
    <$fh>;
};

# The first version of this guard read only the %method table and asserted
# "every dispatchable command has a usage line". It passed, and it was wrong:
# %method is one of two dispatch routes, and 49 commands answered by the
# earlier if/elsif branches - police, next, policy.*, login.*, backup.*,
# project.*, question.attach, question.voice among them - still printed a bare
# [options]. A guard that reads one route and speaks for the whole surface is
# the same shape as the checklist.update usage line this file exists about: it
# looks exhaustive, so nobody checks. Codex review caught it, 2026-08-27.
#
# So the surface is both routes, and the outstanding ones are named rather than
# quietly excluded. The list is a ledger, not an allowance: nothing may join it
# without this test failing, and it shrinks as the lines get written.
#
# Tested through _usage() rather than _skills_usage_line() because _usage is
# what --help actually prints - project.create has its line hard-coded there
# and no SKILLS.md entry, so the lower-level check called it undocumented.

my %command;
$command{$1} = 1 while $cli =~ /\$command\s+eq\s+'([a-z][a-z0-9.\-]*)'/g;
my ($table) = $cli =~ /my \%method\s*=\s*\((.*?)\n    \);/s;
ok( $table, 'found the dispatch table to read the command list from' );
$command{$1} = 1 while $table =~ /'([a-z][a-z0-9.\-]*)'\s*=>/g;

cmp_ok( scalar keys %command, '>', 100,
    'both dispatch routes were read, not just the method table' );

my %known_bare = map { $_ => 1 } qw(
  agent.sessions backup backup.export backup.import backup.restore
  card.holes card.required check.owner column.roles conversation.add
  conversation.list doctor dwell.report gates.install next notify.moves
  onboard police police.log police.outstanding police.suspend policies
  policy.bridge policy.bridge.logs policy.decline policy.declined
  policy.review policy.undeclared project.gates project.limit
  project.link-types.add project.link-types.list project.link-types.remove
  project.mode project.new project.people.add project.people.list
  project.people.remove project.people.update project.show project.validate
  question.attach question.voice record.clone record.create record.update
  rule.suspend tasklist.sessions worklog.show
);

my @bare = sort grep { Tira::CLI::_usage($_) =~ /\Q [options] \E/ } keys %command;
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
    ok( defined Tira::CLI::_skills_usage_line($command),
        "$command has a usage line - it is used at every gate and its flags are not guessable" );
}

# --- the mandatory pair is named where it is mandatory ------------------------
#
# Both of these refuse --status done without at least one --command/--proof
# pair. A usage line that omits the pair describes a command that does not
# exist.

for my $command (qw(checklist.update required-action.update)) {
    my $line = Tira::CLI::_skills_usage_line($command) // '';
    like( $line, qr/--command/,
        "${command}'s usage line names --command, which it refuses done without" );
    like( $line, qr/--proof/,
        "${command}'s usage line names --proof, for the same reason" );
}

# --- a line that names them is not enough if it reads as optional -------------
#
# The pair is required together and repeatable. Written as two separate
# bracketed optionals it would be true about the parser and false about the
# command, which is the failure this whole file is about one level down.

for my $command (qw(checklist.update required-action.update)) {
    my $line = Tira::CLI::_skills_usage_line($command) // '';
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
