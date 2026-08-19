#!/usr/bin/env perl
# --help answers with the literal word '[options]' and lists none of them.
#
# Measured across six commands in one evening: link.add, column.add,
# checklist.add, evidence.add, gate.add, column.update. Each refuses a bad
# call with an excellent, specific message - "Checklist status is required",
# "the option is --result" - but only after the call is made. Asked BEFORE
# trying, --help says nothing more than the bare word "options".
#
# SKILLS.md already carries the real line for every one of these - the exact
# catalogue docs-match-code holds every shipped command to - and _usage() in
# this file never read it, building a second, much thinner answer instead.
# Two copies of "what does this command take", one of them nearly empty.

use strict;
use warnings;

use File::Spec;
use Test::More;

use lib 'lib';
use Tira::CLI;

# --- the six measured commands now say something real -----------------------

my %expect = (
    'link.add'       => [qr/--from/,    qr/--to/],
    'column.add'     => [qr/--name/],
    'checklist.add'  => [qr/--item/,    qr/--status/],
    'evidence.add'   => [qr/--summary/],
    'gate.add'       => [qr/--result/],
    'column.update'  => [qr/--type/,    qr/--name/],
);

for my $command ( sort keys %expect ) {
    my $usage = Tira::CLI::_usage( $command, undef );
    unlike( $usage, qr/\[options\]\s*\[-o/,
        "tira.$command --help no longer answers with a bare [options]" )
      or diag($usage);
    for my $pattern ( @{ $expect{$command} } ) {
        like( $usage, $pattern, "and names $pattern" );
    }
    like( $usage, qr/^Usage: dashboard tira\.\Q$command\E\b/,
        'still names the command that was actually asked about' );
}

# --- additive, not a new way to fail: an unknown command keeps the old answer ---

{
    my $usage = Tira::CLI::_usage( 'nonexistent.verb', undef );
    like( $usage, qr/\[options\]/,
        'a command genuinely absent from SKILLS.md falls back to the placeholder, not an error' );
}

# --- the record-verb branch is untouched - a harder bug, already fixed -------
#
# TKT-235 hand-fixed this one, and its shorthand ([record field arguments])
# matches SKILLS.md's own convention rather than hiding something SKILLS.md
# spells out. Reasserted narrowly here so a change to the generic fallback
# cannot silently reach this branch too.

like( Tira::CLI::_usage( 'record.move', 'ticket' ), qr/tira\.ticket\.move/,
    'a record verb still names itself, not a fallback' );
like( Tira::CLI::_usage( 'record.create', 'ticket' ), qr/\[record field arguments\]/,
    'and still uses its own established shorthand, not this fix\'s lookup' );

# --- proved by breaking it: without the lookup, the old bare answer returns ---

{
    no warnings 'redefine';
    local *Tira::CLI::_skills_usage_line = sub { return undef };

    for my $command (qw(link.add gate.add column.update)) {
        my $usage = Tira::CLI::_usage( $command, undef );
        like( $usage, qr/\[options\]/,
            "without the lookup, tira.$command reverts to the bare placeholder - the exact defect" );
    }
}

done_testing;

__END__

=head1 NAME

283-a-usage-line-that-lists-nothing.t - TKT-343

=head1 DESCRIPTION

C<--help> for any command outside the hand-fixed record-verb branch printed
the literal word C<[options]> with none listed, forcing a trip to
C<tira.usage> or a failed first attempt to learn what a command actually
needs. C<_usage()> now looks up the real line from SKILLS.md - the same
catalogue C<docs-match-code> already holds every shipped command to - before
falling back to the old placeholder, so nothing is duplicated and a command
missing from the catalogue fails no differently than it did before.

=cut
