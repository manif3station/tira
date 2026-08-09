#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use Test::More;

# The owner asked for the question surface to be documented completely. "I read
# it and it looks complete" is not a check, so this enumerates the commands and
# their options FROM THE CODE and fails when either manual omits one. A manual
# that is ninety percent complete is one an agent cannot trust, because it
# cannot tell which tenth is missing.

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot read '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    return $body;
}

my $reference = slurp('docs/commands.md');
my $manual = slurp('SKILLS.md');

# Scope every check to the questions section. These flags appear all over the
# reference for other commands, so searching the whole file would pass while
# the question tables were missing them - which is exactly what it did.
my ($questions) = $reference =~ /(^## Questions on cards.*?)^## /ms;
ok( $questions, 'the reference has a questions section to check' );

# Every question command that actually ships, taken from the entrypoints.
my @commands = sort map { ( File::Spec->splitdir($_) )[-1] }
  grep { -f } glob 'skills/question/cli/*';
is_deeply( \@commands, [qw(answer ask discard list mark update voice)],
    'the question commands are the seven that ship' );

for my $command (@commands) {
    like( $questions, qr/\Qtira.question.$command\E/,
        "the reference documents tira.question.$command" );
}

# Every option the dispatcher actually passes through to a question command.
my $cli = slurp('lib/Tira/CLI.pm');
my ($dispatch) = $cli =~ /(if \( \$command =~ \/\\Aquestion.*?\n    \})/s;
ok( $dispatch, 'the question dispatch block is where it is expected' );
my %passed;
$passed{$_} = 1 for map { split ' ' } $dispatch =~ /qw\(([^)]+)\)/g;
$passed{$_} = 1 for $dispatch =~ /\$question\{(\w+)\}/g;
delete @passed{qw(project)};

my %flag = (
    ref => '--ref', id => '--id', text => '--text', reason => '--reason',
    options => '--option', mark => '--mark', author => '--author',
    status => '--status', since => '--since', voice => '--voice',
);
for my $key ( sort keys %passed ) {
    my $flag = $flag{$key} or next;
    like( $questions, qr/\Q$flag\E/,
        "the questions section documents $flag, which the dispatcher passes through" );
}
ok( scalar keys %passed >= 8, 'and the dispatcher really does pass a full option set' );

# The behaviour an agent has to know about, not just the syntax.
my %explained = (
    'project-wide references' => qr/project-wide|Q-007 reaches/i,
    'the three statuses' => qr/`new`.*`answered`.*`discarded`/s,
    'reading marks answers read' => qr/[Rr]eading is what\s+marks/s,
    'a cross obliging a new question' => qr/cross settles\s+nothing/is,
    'only what you name changing' => qr/[Oo]nly what you name\s+changes/s,
    'a blocked card not being chased' => qr/not chased|leaves it\s+alone/is,
    'the clock restarting from the answer' => qr/restarts the clock\s+from that answer/s,
    'what a card\'s appearance means' => qr/appearance says whose move/is,
    'yellow being the owner\'s move' => qr/Yellow: a question nobody\s+has\s+answered/s,
    'the agent\'s cards being greyed out' => qr/Greyed out: everything\s+answered/s,
    'clicking a choice to answer' => qr/clicking one answers\s+with it/is,
    'the board and CLI being one path' => qr/same engine\s+subroutine/s,
    'Tira not making the recording itself' => qr/Tira does not make the\s+recording/s,
    'the reminders an agent will be given' => qr/Reminders you will be given/,
);
for my $what ( sort keys %explained ) {
    like( $questions, $explained{$what}, "the reference explains $what" );
}

# SKILLS.md carries the workflows, which is what it is for.
# Count what each use case is about, not how its title happens to be worded.
my @blocks = split /^### UC-/m, $manual;
my @about_questions = grep { /tira\.question\.|questions? on (?:a|the) card/i } @blocks;
my %workflow = (
    'asking on a card' => qr/ask about a card|Ask about a card/i,
    'reading and marking' => qr/tira\.question\.mark/,
    'catching up by status or time' => qr/--status new|--since/,
    'asking with reason and choices' => qr/--reason.*--option/s,
    'answering from the board' => qr/Questions.*section|in one click/is,
    'decomposing a crammed question' => qr/crammed|decompose/i,
);
for my $what ( sort keys %workflow ) {
    like( $manual, $workflow{$what}, "the manual covers $what" );
}
ok( scalar @about_questions >= 5,
    'and gives the question workflows at least five use cases of their own' );

# Neither manual may leak how projects are selected.
unlike( $questions, qr/TIRA_HOME|\.tira\//, 'the reference discloses no project location' );

done_testing;

__END__

=head1 NAME

64-question-docs.t - DD-483 the question surface is documented completely

=head1 DESCRIPTION

Enumerates the question commands and the options the dispatcher passes
to them from the code itself, then fails if either manual omits one, so
the documentation cannot drift away from the surface it describes.
Checks the behaviour an agent has to know as well as the syntax: that
references are project-wide, that reading marks answers read, that a
cross obliges a new question, that a blocked card is not chased, and
that the board and the command line are one path underneath.

=cut
