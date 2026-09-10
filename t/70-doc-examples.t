#!/usr/bin/env perl

use strict;
use warnings;

use Cwd ();
use Test::More;

use lib 't/lib';
use Suite ();
# An agent reported twenty-seven failed attempts against an example in the
# manual that named a flag the command does not take. The existing doc test
# checked that flags were *mentioned* somewhere in the section, which a wrong
# example passes happily. This one runs the examples through the real option
# parser, so an example that cannot work fails the suite.

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot read '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    return $body;
}

my $cli = Suite::cli_source();

# Every flag the parser actually declares, taken from the parser itself rather
# than from a list somebody has to remember to update.
my ($spec) = $cli =~ /my \@spec = \(\n(.*?)\n    \);/s;
ok( $spec, 'the option specification is where it is expected' );
my %known;
while ( $spec =~ /'([a-z0-9|_-]+)(?:[=:][si]@?)?(!)?'/gi ) {
    my ( $names, $negatable ) = ( $1, $2 );
    for my $name ( map { s/_/-/gr } split /\|/, $names ) {
        $known{$name} = 1;

        # Getopt::Long's own convention for a spec ending in "!": one name
        # in the source, two on the command line - --watch and --no-watch
        # both come from 'watch!'. A catalogue line documenting --no-watch
        # is documenting the real flag, and this is what makes that visible
        # rather than reading as an option the parser was never told about.
        $known{"no-$name"} = 1 if $negatable;
    }
}
ok( scalar keys %known > 40, 'and it declares a full set of options' );
$known{$_} = 1 for qw(o);

# A pipe stops the capture, so an example does not bleed into a following
# inline-code span or a markdown table cell. That same character is also how
# the catalogue writes a flag's value alternatives - "--result
# pass|fail|blocked" - with no space on either side of it, unlike a table
# pipe, which always has one. So a pipe only stops the capture where it looks
# like a table cell boundary (whitespace beside it); one sitting tight between
# two words is read as part of the value it is inside.
#
# Found rather than assumed: gate.add's own catalogue line reads
# "--result pass|fail|blocked --details TEXT ...", and stopping at the first
# pipe silently dropped --details from what was actually tested - invisible
# while gate.add did not yet check for it, and exposed the moment TKT-408
# added the check. The catalogue line was correct the whole time; only the
# extraction was truncating it. TKT-408.
# TKT-900. Derived rather than typed, so a new documentation file is gated
# by being created under docs/ rather than by somebody remembering to add
# its name here - which is exactly how docs/JOBS.md arrived outside this
# gate the first time, written by someone who knew this test existed.
my @files = sort ( 'SKILLS.md', glob('docs/*.md') );
cmp_ok( scalar @files, '>=', 4, 'at least the four known documentation files were found' );

my @examples;
my %per_file;
for my $file (@files) {
    my $body = slurp($file);

    # TKT-900. A shell line continuation ("\" at the end of a line) is one
    # logical command split across two - docs/POLICIES.md's own
    # policy.decline example is exactly this shape, --reason on the second
    # line. The old (SKILLS.md, docs/commands.md) pair never happened to
    # carry one, so nothing joined them before. Joined here, before the
    # harvest regex runs, rather than widening that regex to cross a
    # newline itself - which would also swallow the fenced block's closing
    # backtick line and everything after it on the next real command.
    $body =~ s/\\\n[ \t]*/ /g;

    while ( $body =~ /((?:dashboard |d2 )?tira\.[a-z.]+(?:[^\n`]|(?<=\S)\|(?=\S))*)/g ) {
        my $line = $1;
        next if $line !~ /--/;
        push @examples, { file => $file, text => $line };
        $per_file{$file}++;
    }
}
ok( scalar @examples > 15, 'the documentation set carries runnable examples to check' );

# Per file, not only in total - a file whose own examples all vanished (the
# fault this ticket's own test_step proves by deleting a file's examples in a
# scratch copy) would still pass a bare total check as long as some OTHER
# file still carried enough. Not every file need carry one - docs/foundation.md
# does not - so this only holds the two files this ticket is actually about.
for my $file (qw(docs/POLICIES.md docs/JOBS.md)) {
    cmp_ok( $per_file{$file} // 0, '>', 0, "${file}'s own examples were harvested, not just the total" );
}

my @broken;
for my $example (@examples) {
    while ( $example->{text} =~ /--([a-z][a-z0-9-]*)/g ) {
        my $flag = $1;
        next if $known{$flag};
        push @broken, "$example->{file}: --$flag in: $example->{text}";
    }
}
is_deeply( \@broken, [],
    'every flag in every documented example is one the parser accepts at all' );

# That check alone is too weak, and knowing why is the point of this test. The
# flag an agent failed on twenty-seven times was --file, which every version of
# Tira has accepted - just not on that command. So each example is actually run,
# and rejected only for the two failures that mean the manual lied: an option
# the parser does not know, or one this command refuses to take.
use File::Spec;
use File::Temp qw(tempdir);
use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-09T09:00:00Z' } );
# Untainted so the chdir below is allowed, and kept for the return trip.
my ($root) = File::Spec->catdir( $tmp, 'docs-project' ) =~ /\A([^\x00-\x1f\x7f]+)\z/;
$tira->project_new( name => 'Docs', dir => $root, members => ['ada'], columns => ['Backlog, Doing'] );

# The examples name TKT-001 and Q-007, so those must exist here or every one of
# them fails on a missing reference before it ever reaches the flag being
# checked - which is exactly how the first version of this test passed against
# the broken build it was written to catch.
my $subject = $tira->create_record( project => $root, type => 'ticket', title => 'Documented card' );
is( $subject->{ref}, 'TKT-001', 'the fixture holds the card the examples name' );
$tira->question_add( project => $root, ref => $subject->{ref}, text => "Question $_" ) for 1 .. 7;
is( $tira->question_list( project => $root, ref => $subject->{ref} )->{questions}[6]{id},
    'Q-007', 'and the question they name' );

# Some documented commands write, and one of them created a directory in the
# repository the first time this ran, from a placeholder taken literally. Every
# attempt now runs inside the throwaway project, so a stray write lands
# somewhere that is deleted rather than in somebody's checkout.
sub attempt {
    my (@argv) = @_;
    my $command = shift @argv;
    my ($return_to) = Cwd::getcwd() =~ /\A([^\x00-\x1f\x7f]+)\z/;
    chdir $root or die "Cannot enter the fixture: $!";
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;

    # TKT-900 widened the harvest to docs/JOBS.md, which documents commands
    # that legitimately read from stdin when piped (job.feed with no --file,
    # for one) - a real usage this test cannot supply. TKT-896 (discarded)
    # is about that being a production hang rather than a refusal; this is
    # narrower and stays in scope: the HARNESS must not hang waiting for
    # input nobody is going to send it, whatever the example is.
    open my $stdin, '<', File::Spec->devnull or die $!;
    {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        local *STDIN  = $stdin;
        eval {
            do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
                command => $command, type => $type,
                argv => [ @argv ], tira => $tira ) };
            1;
        };
    }
    chdir $return_to or die "Cannot leave the fixture: $!";
    return $err;
}

my @rejected;
for my $example (@examples) {
    my $text = $example->{text};
    $text =~ s/\A(?:dashboard|d2)\s+//;

    # Hyphens belong in a command name as much as dots do -
    # required-action.update is a real command, and excluding '-' here
    # truncated it to 'required', which then failed for a reason that had
    # nothing to do with the example: not a real rejection, a parsing bug in
    # this test silently mistaking one command for a different, shorter one.
    next if $text !~ /\Atira\.([a-z.-]+)/;
    my $command = $1;
    $command =~ s/[.,)]\z//;

    # TKT-900. job.add's own documented examples create a REAL monitor-kind
    # job on the fixture board (docs/JOBS.md's widened harvest carries
    # several) - the first one gets id JOB-001, exactly the id job.start's
    # AND job.run's own documented examples name (docs/commands.md:4550
    # and docs/JOBS.md:277 both read "d2 tira.job.run --id JOB-001"). A
    # later example naming that id is then a job that genuinely exists,
    # and both job.start and job.run (run_now, for a monitor-kind job)
    # spawn a real process (open3, TKT-920) rather than refusing - out of
    # scope for a test about flag ACCEPTANCE, and unsafe to do for real
    # against documentation examples nobody wrote expecting execution.
    # job.feeder is the same process, one call closer to the fork.
    next if $command =~ /\A(?:job\.start|job\.feeder|job\.run)\z/;

    # Placeholders stand in for real values; this is about whether the command
    # accepts the shape of the example, not whether the values exist.
    my @argv = ($command);
    my @tokens = $text =~ /(--[a-z][a-z0-9-]*)(?:\s+((?:"[^"]*")|(?:[^\s-][^\s]*)))?/g;
    while ( my ( $flag, $value ) = splice @tokens, 0, 2 ) {
        push @argv, $flag;
        next if !defined $value;
        $value =~ s/\A"|"\z//g;

        # "pass|fail|blocked" is three alternative values, not one literal
        # string containing two pipes - the same shape the capture above now
        # reads across rather than stopping at. A real caller supplies one of
        # them; the first is as good as any for testing that the command
        # accepts the flag at all.
        ($value) = split /\|/, $value, 2 if $value =~ /\A\S+\|\S/;

        push @argv, $value;
    }
    my $error = attempt(@argv);
    push @rejected, "$example->{file}: $text -> $error"
      if $error =~ /Unknown option|belongs to the|is available on|available on the/i;

    # The failure that actually cost an agent twenty-seven attempts was quieter
    # than a rejection: the command ignored the flag it was given and then
    # complained that the very thing was missing. Being told you must supply
    # what you just supplied is the most confusing failure a tool can produce,
    # so a contradiction between what the example passes and what the error
    # asks for is treated as a broken example.
    #
    # AN EXPLICIT "does not act on --FLAG" IS THE OPPOSITE OF THAT and is not a
    # contradiction: it is the option guard saying, in the clearest words the
    # tool has, that this command does not read the flag. Several documented
    # examples exist precisely to show that refusal, and they are checked by
    # t/239 rather than here.
    #
    # It has to be excluded because the heuristic below cannot tell a word from
    # a command name. `required-action.list` contains "require", so any refusal
    # whose "use this instead" text points at that command reads as a demand
    # for the flag it just refused. That is how --status arrived: a correct
    # message, naming the four lists that can filter, failing this test for
    # naming one of them. TKT-748.
    next if $error =~ /does not act on --[a-z][a-z0-9-]*/;

    # TKT-900. THE SAME FAULT, A THIRD SHAPE: an INVALID VALUE, not a missing
    # flag. Tira::CLI::Usage's own table appends "- the option is --FLAG" to
    # several "invalid value" refusals precisely so the flag is named rather
    # than left for the reader to guess - `tira.policy.add --rule RULE`
    # (SKILLS.md's own placeholder) refuses with "Unknown policy rule
    # 'RULE'. Rules: ... gate-missing, ... - the option is --rule", and the
    # word "missing" inside the RULE NAME "gate-missing" in that enumerated
    # list, combined with the flag's own name legitimately appearing in
    # "Unknown policy RULE", reads as a demand for the very flag that was
    # supplied. It is the opposite: the option is named to say WHICH one
    # got an invalid value, the same diagnostic intent "does not act on"
    # already gets excluded for above.
    next if $error =~ /the option is --[a-z][a-z0-9-]*/;

    next if $error !~ /need|require|missing/i;

    # TKT-900. A FOURTH SHAPE of the same fault: the flag's own VALUE, once
    # rejected for a reason that has nothing to do with the flag, gets
    # echoed back in the refusal - "Policy rule 'card-sandbox-missing'
    # reads ... this project is not in one" - and that echoed value can
    # itself contain "missing" (most police rule names do) or the bare
    # word "rule" can appear as ordinary prose ("Policy rule '...'") wholly
    # apart from the --rule flag. A value the error quotes back is proof
    # the flag was received, not proof it was withheld - the opposite of
    # what a real contradiction shows.
    # A fifth shape, and the reason the fourth (checking THIS flag's own
    # value) still was not enough: "card-sandbox-missing", the RULE NAME
    # ITSELF - not this example's --sandbox value at all - is quoted back
    # in the error, and "sandbox" is one of the hyphen-joined words inside
    # it. Rule names are compounds of exactly the vocabulary these errors
    # use (card, sandbox, missing, gate, ...), so any word quoted back as
    # somebody ELSE's identifier reads as a demand for a flag sharing that
    # word. A flag named only INSIDE a quoted identifier is not a bare
    # demand for it - a real "X is required" names X outside quotes.
    ( my $unquoted_error = $error ) =~ s/'[^']*'//g;

    while ( $text =~ /--([a-z][a-z0-9-]*)\s+(?:"([^"]*)"|([^\s-][^\s]*))/g ) {
        my ( $flag, $value ) = ( $1, $2 // $3 );
        next if defined $value && $value ne '' && $error =~ /\b\Q$value\E\b/i;
        push @rejected, "$example->{file}: passes --$flag yet is told it is missing -> $error"
          if $unquoted_error =~ /\b\Q$flag\E\b/i;
    }
}

# THE NARROWING ABOVE MUST NOT HAVE DISABLED THE CHECK, and nothing else in
# this file would notice if it had - a guard that silently stops guarding is
# the failure this whole file exists to catch, one level up. So the heuristic
# is run against a contradiction built here, where the answer is known.
{
    my @caught;
    for my $case (
        [ 'tira.thing.do --widget red',
            'Widget is required', 1, 'a demand for the flag that was supplied' ],
        [ 'tira.thing.do --widget red',
            'thing.do does not act on --widget. Use required-action.list.',
            0, 'an explicit refusal by name, even one naming required-action.list' ],
        [ 'tira.thing.do --widget red',
            'A card reference is required', 0, 'a demand for something else' ],
        [ 'tira.policy.add --rule RULE',
            "Unknown policy rule 'RULE'. Rules: gate-missing, wip-limit - the option is --rule",
            0, 'an invalid-value refusal naming the option, even one a rule list makes look like a demand' ],
        [ 'tira.policy.decline --rule card-sandbox-missing',
            "Policy rule 'card-sandbox-missing' reads a git repository, and this project is not in one",
            0, 'the value it was given echoed back, proving the flag was received rather than missing' ],
        [ 'tira.policy.add --rule card-sandbox-missing --enter implement --sandbox ~/x --action bridge-reminder',
            "Policy rule 'card-sandbox-missing' reads a git repository, and this project is not in one",
            0, 'a DIFFERENT flag (--sandbox) only sharing a word with a quoted identifier (card-sandbox-missing) that names something else entirely' ],
      )
    {
        my ( $text, $error, $want, $why ) = @{$case};
        my $flagged = 0;
        if ( $error !~ /does not act on --[a-z][a-z0-9-]*/
            && $error !~ /the option is --[a-z][a-z0-9-]*/
            && $error =~ /need|require|missing/i )
        {
            ( my $unquoted_error = $error ) =~ s/'[^']*'//g;
            while ( $text =~ /--([a-z][a-z0-9-]*)\s+(?:"([^"]*)"|([^\s-][^\s]*))/g ) {
                my ( $flag, $value ) = ( $1, $2 // $3 );
                next if defined $value && $value ne '' && $error =~ /\b\Q$value\E\b/i;
                $flagged = 1 if $unquoted_error =~ /\b\Q$flag\E\b/i;
            }
        }
        push @caught, [ $flagged, $want, $why ];
    }
    is( $caught[$_][0], $caught[$_][1], "the contradiction check still reads $caught[$_][2]" )
      for 0 .. $#caught;
}
is_deeply( \@rejected, [],
    'and no example uses an option the command it names would refuse' );

done_testing;

__END__

=head1 NAME

70-doc-examples.t - every documented example is runnable

=head1 DESCRIPTION

An agent reported twenty-seven consecutive failures against a manual
example that named a flag the command does not take. Checking that a
flag is mentioned somewhere in a section does not catch that, because a
wrong example mentions it too. This reads the option specification out
of the parser and every example out of the documentation set - SKILLS.md
and every file under docs/ - and fails when an example uses a flag no
command accepts, so the documentation cannot promise something the tool
will refuse. TKT-900 widened the set from a hardcoded (SKILLS.md,
docs/commands.md) pair, since docs/JOBS.md arrived outside the gate
entirely, written by someone who knew this test existed.

=cut
