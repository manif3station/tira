#!/usr/bin/env perl
# A project that reported a bug can find out it was fixed.
#
# Other projects file bugs here now, through tira.dev.found.bug_or_improvement,
# and seven arrived in one evening. There was no command that told them what
# happened next. Three documentation commands print the manual, the command
# reference and the policies guide, and none of them says what changed.
#
# His words: "there are three documentation command lines - tira.skills, then
# tira.usage, third tira.policies. Now open one called changes, that just prints
# out the Changes file. Four documentation command lines, so an agent does not
# have to print several thousand words at once - he may only want the usage, or
# only the skill. The purpose is that they can run tira.changes next time and
# know the bug they reported is fixed."
#
# It only works because every entry names its ticket, which is the other half he
# asked for and has its own card. A changes command printing entries nobody can
# match to a report answers nothing.

use strict;
use warnings;

use File::Spec;
use Test::More;

my $root = File::Spec->rel2abs('.');

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

# --- the command exists and is runnable ---------------------------------------

my $entrypoint = File::Spec->catfile( $root, 'cli', 'changes' );
ok( -f $entrypoint, 'there is an entrypoint for tira.changes' );
ok( -x $entrypoint, 'and it is runnable, like the three beside it' );

# --- it prints the changelog and nothing else ----------------------------------

my $printed = do {
    local $ENV{PERL5OPT}              = '';
    local $ENV{HARNESS_PERL_SWITCHES} = '';
    open my $fh, '-|', $^X, $entrypoint or die $!;
    local $/;
    my $text = <$fh>;
    close $fh;
    $text // '';
};
my $changes = slurp( File::Spec->catfile( $root, 'Changes' ) );
is( $printed, $changes, 'it prints the changelog exactly, with nothing added and nothing left out' );

# --- and what a reporter came for is in it --------------------------------------
#
# The whole point. A project that raised a card must be able to find that card's
# number in what this prints, or the command answers nothing.

like( $printed, qr/TKT-\d+/,
    'the changelog names the cards its entries came from, which is what a reporter searches for' );

# --- it stands beside the other three -------------------------------------------
#
# Four commands rather than one for the reason he gave for the first three: an
# agent that wants the usage should not have to print several thousand words of
# everything else to reach it. A command nobody is told about is a command
# nobody runs.

my $manual = slurp( File::Spec->catfile( $root, 'SKILLS.md' ) );
like( $manual, qr/tira\.changes/, 'the manual names it' );
my ($para) = grep { /tira\.changes/ } split /\n\n/, $manual;
like( $para, qr/chang/i, 'and says what it prints' );

for my $sibling (qw(tira.skills tira.usage tira.policies)) {
    like( $manual, qr/\Q$sibling\E/, "the manual still names $sibling" );
}

done_testing;

__END__

=head1 NAME

145-a-reporter-can-see-it-was-fixed.t - tira.changes prints the changelog

=head1 DESCRIPTION

Other projects file bugs here now and had no way to learn what happened to them.
C<tira.changes> is the fourth documentation command, beside C<tira.skills>,
C<tira.usage> and C<tira.policies>: it prints the changelog and nothing else, so
a reporter can find the card they raised without printing the whole manual to
get at it.

It depends on every entry naming its ticket, which is the other half of the same
request and has its own card.

=cut
