#!/usr/bin/env perl

use strict;
use warnings;

BEGIN {
    if (${^TAINT}) {
        $ENV{PATH}   = '/usr/bin:/bin';
        $ENV{TMPDIR} = '/tmp';
        delete @ENV{qw(IFS CDPATH ENV BASH_ENV PERL5LIB PERLLIB PERL_USE_UNSAFE_INC)};
    }
}

use Pod::Checker qw(podchecker);
use File::Find qw(find);
use Test::More;

for my $file (qw(.env Changes LICENSE README.md SKILLS.md docs/foundation.md docs/commands.md cpanfile)) {
    ok( -f $file, "$file exists" );
}

open my $env, '<', '.env' or die "Cannot read .env: $!";
my $env_text = do { local $/; <$env> };
close $env;
like( $env_text, qr/^VERSION=5\.43$/m, '.env stores the version being released' );

# Read out of .env rather than matched against it, so the module can be
# compared with what .env actually holds rather than with a literal that
# happens to appear in two assertions.
my ($env_version) = $env_text =~ /^VERSION=(\S+)$/m;
ok( defined $env_version, '.env names a version at all' );

open my $skills, '<', 'SKILLS.md' or die "Cannot read SKILLS.md: $!";
my $skills_text = do { local $/; <$skills> };
close $skills;
for my $section (
    'Availability legend', 'Global invocation grammar', 'Argument precedence',
    'Command catalogue', 'Record field arguments', 'Exit status contract',
    'Concurrency and transaction semantics',
) {
    like( $skills_text, qr/^## \Q$section\E$/m, "SKILLS.md contains $section" );
}

# The use-cases heading names its own count, and that number is a claim
# rather than a title - checked here against the same count it names,
# instead of a second hardcoded literal that would only reproduce the bug
# this guards. A literal number in this list drifted for 336 commits before
# TKT-413: git log -S"## 100 use cases" -- SKILLS.md finds exactly one
# commit, the file's own foundation, 2026-08-05. The catalogue grew from 100
# to 137 real use cases and the heading never moved, because nothing ever
# read its number back.
my ($heading_claim) = $skills_text =~ /^## (\d+) use cases$/m;
ok( defined $heading_claim, 'SKILLS.md contains a use-cases section' );
my @use_cases = $skills_text =~ /^### UC-\d{3}:/mg;
cmp_ok( scalar @use_cases, '>=', 100, 'and there are use cases to count' );
is( $heading_claim, scalar @use_cases,
    'and the heading names how many there really are' );
my %seen;
while ( $skills_text =~ /^### UC-(\d{3}):/mg ) {
    $seen{$1}++;
}
is_deeply( [ sort keys %seen ], [ map { sprintf '%03d', $_ } 1 .. scalar @use_cases ],
    'use cases are numbered UC-001 through the count above, with no gap or duplicate' );
unlike( $skills_text, qr{/home/[A-Za-z0-9._-]+/}, 'SKILLS.md contains no hard-coded home-directory path' );
unlike( $skills_text, qr/--project|TIRA_HOME|\.tira\/|project selector/i, 'SKILLS.md does not disclose project location or selectors' );

use lib 'lib';
use Tira;
# Two assertions, because they promise two different things and used to be one.
#
# This one said "module version matches .env" and never read .env: it compared
# the module against a literal, while another assertion compared .env against
# the same literal, so they agreed only through a third party. Changing one
# literal and not the other was caught by luck rather than by this.
is( $Tira::VERSION, $env_version, 'module version matches .env, which is now read' );
is( $Tira::VERSION, '5.43', 'and the release being made is the one intended' );

# And the changelog, which nothing checked. .env, the module and this file
# agreed with each other for two releases while Changes named a version one
# behind, because no gate compared them - and a changelog that names the wrong
# version is the file somebody reads to find out what they are running.
open my $changes, '<', 'Changes' or die "Cannot read Changes: $!";
my $history = do { local $/; <$changes> };
close $changes;
my ($newest) = $history =~ /^(\d+\.\d+)\s/m;
is( $newest, $Tira::VERSION, 'the changelog names this release at the top' );

# And which card it came from. Other projects file bugs here now, and
# tira.changes exists so they can find out what happened to one - which works
# only if the entry names the card they raised. An entry that describes the fix
# in prose leaves the reporter reading and guessing.
#
# Only this release is checked. Entries written before the rule existed do not
# carry a reference and will not be given one from memory: for some the card
# could be recovered from the commit that names it, for others it could only be
# guessed, and a guessed reference in the one file whose purpose is traceability
# is worse than an absent one.
my ($top) = $history =~ /^\Q$newest\E\s[^\n]*\n(.*?)(?=^\d+\.\d+\s|\z)/ms;
like( $top, qr/\b(?:TKT|EPC|SOW)-\d+/,
    'and this release names the card its entries came from, so a reporter can find it' );
unlike( $skills_text, qr/\bSpecified\b/i, 'every documented command and use case is implemented' );

# A count written in prose goes stale the moment a rule is added, and nothing
# says so - SKILLS.md claimed twenty while twenty-two shipped.
#
# The count itself moved to t/433 in 4.76 and is deliberately not checked twice
# here. This line used to read
#
#     my ($claimed) = $skills_text =~ /(\d+) rules cover/;
#
# which matched one phrasing of a sentence that appears in three places, so every
# rule added since has demanded that one sentence be updated and said nothing
# about "the 36 rules police itself" two thousand lines earlier - four rules
# behind by the time anyone looked. Its existence is what made the drift
# invisible: a number nobody checks is obviously unreliable and gets re-read, a
# number that IS checked reads as reliable. Two checks of one fact is the shape
# that produced the bug; t/433 is the one.
#
# Every rule is also named in the policies guide, so a rule added without being
# documented is caught by name rather than by arithmetic.
my $rules = Tira->new->policy_rules;

open my $policies_doc, '<', 'docs/POLICIES.md' or die "Cannot read docs/POLICIES.md: $!";
my $policies_text = do { local $/; <$policies_doc> };
close $policies_doc;
my @rules_undocumented = grep { $policies_text !~ /\Q$_\E/ } @{$rules};
is_deeply( \@rules_undocumented, [], 'every rule is named in the policies guide' );

my @perl_files = ( 'lib/Tira.pm', 'lib/Tira/CLI.pm' );
find( { no_chdir => 1, wanted => sub {
    return if !-f $File::Find::name;
    return if $File::Find::name !~ m{(?:\A|/)cli/[^/]+\z} && $File::Find::name !~ m{\At/.*\.t\z};
    $File::Find::name =~ /\A([^\x00-\x1f\x7f]+)\z/ or die 'Unsafe Perl file path';
    push @perl_files, $1;
} }, qw(cli skills t) );
for my $file (@perl_files) {
    is( podchecker($file), 0, "$file has valid POD" );
    open my $fh, '<:raw', $file or die "Cannot read '$file': $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    my ($pod) = $body =~ /^__END__\s*(.*)\z/ms;
    is_deeply( [ ( $pod // '' ) =~ /([^\x00-\x7f])/g ], [],
        "$file keeps its POD ASCII, which podchecker requires without an =encoding" );
}
# Executability is what makes a file a command on a POSIX system and is not a
# concept on Windows, where -x answers for the extension rather than the file.
# Checking it where it means something keeps the guard honest without making
# the count platform-dependent.
my @commands = grep { m{(?:\A|/)cli/[^/]+\z} && ( $^O eq 'MSWin32' || -x $_ ) } @perl_files;

# Twenty-one entrypoints shipped in 1.05 with not one of them named in the
# command reference or in SKILLS.md. Every documentation guard passed, because
# each checked that what was written was correct and none checked that what
# existed was written. An agent reads these documents before it reads anything
# else, so a command missing from them is a command nobody will find, however
# well it works.
my $documented = '';
for my $document (qw(docs/commands.md SKILLS.md docs/POLICIES.md)) {
    open my $fh, '<', $document or die "Cannot read $document: $!";
    $documented .= do { local $/; <$fh> };
    close $fh;
}

# The command an agent types, from the path the file sits at, derived once.
#
# The dispatcher drops every 'skills' segment, so the name is not the path -
# and an entrypoint sitting directly in cli/ is named by its basename instead,
# which is the branch this used to be missing. Without it, cli/skills - the
# file behind d2 tira.skills - derived to the bare 'tira.', which appears in
# every document, so that command was reported documented without anything
# having been checked. Removing it from all three documents changed nothing:
# the check was not weak on that command, it was incapable of failing on it.
#
# Written once and called from both places that need it, because the guard
# below already had the branch and holding two derivations of one decision in
# one file is the shape this project keeps finding. TKT-224.
sub dotted_command {
    my ($path) = @_;
    return "tira.$1" if $path =~ m{\Acli/([^/]+)\z};
    ( my $trimmed = $path ) =~ s{/cli/}{/};

    # The dispatcher's own nested lookup (Developer::Dashboard::SkillDispatcher
    # _nested_skill_path) requires a literal 'skills' segment immediately
    # before every dotted-name segment past the first, not merely somewhere in
    # the path - a name/name/name/cli/action chain looks like it resolves (the
    # words are all there) but the dispatcher never finds it. TKT-510 shipped
    # exactly that shape and every prior version of this check derived the
    # right-looking dotted name from it anyway, so "every documented command
    # resolves" passed on a command that could not be typed. Requiring strict
    # alternation here means a future misplaced entrypoint fails this test
    # instead of shipping silently.
    my @parts = split m{/}, $trimmed;
    shift @parts;    # the top-level skills/ container itself, not part of the name
    my $action = pop @parts;
    die "Malformed nested entrypoint path '$path': odd chain of name/skills segments expected\n"
      if @parts % 2 == 0;
    my @names;
    for my $i ( 0 .. $#parts ) {
        if ( $i % 2 == 0 ) {
            push @names, $parts[$i];
        }
        else {
            die "Malformed nested entrypoint path '$path': expected a literal "
              . "'skills' segment, found '$parts[$i]'\n"
              if $parts[$i] ne 'skills';
        }
    }
    push @names, $action;
    return 'tira.' . join '.', @names;
}

my @undocumented;
for my $command (@commands) {
    my $dotted = dotted_command($command);

    # The three record boards share one set of verbs, documented once.
    next if $dotted =~ /\Atira\.(?:sow|epic|ticket)\./;
    next if $dotted =~ /\Atira\.dashboard\./;
    push @undocumented, $dotted if index( $documented, $dotted ) < 0;
}

# And the derivation itself, on the one entrypoint that exposed the fault: a
# guard whose subject is a derived name is only as good as the derivation.
is( dotted_command('cli/skills'), 'tira.skills',
    'an entrypoint in cli/ is named by its basename, as the dispatcher names it' );
is( dotted_command('skills/project/skills/people/cli/remove'),
    'tira.project.people.remove',
    'and a nested one drops the segments the dispatcher drops' );
is_deeply( \@undocumented, [],
    'every command that ships is named in a document an agent reads' );

is( scalar @commands, 189, 'release ships exactly 189 executable CLI entrypoints' );

# --- and every command the documents name can be run --------------------------
#
# The check above and t/162 both run one way: every command that SHIPS is named
# in a document. Nothing ran the other way, and two documented signatures -
# tira.comment.remove with --ref and --comment, tira.attachment.detach with
# --sha and --extension - pointed at entrypoints that had never existed. The
# engine methods were there and tested, the CLI dispatched them, and a reader
# who typed either was told the command does not exist.
#
# That is the same failure TKT-194 reported from the other side: somebody
# concluded a shipped capability was missing. Here the documentation promises
# one that cannot be typed, and the reasonable conclusion is that the
# documentation is stale.

{
    # The dotted name each entrypoint answers to, derived the way the
    # dispatcher derives it. @commands holds PATHS; comparing those against
    # documented names would report all 136 as unrunnable, which is what the
    # first draft of this guard did.
    #
    # An entrypoint sitting directly in cli/ is named by its basename. Dropping
    # 'skills' segments without that branch turns cli/skills into the bare
    # 'tira.', which then matches the documentation trivially - TKT-224.
    my %ships = map { dotted_command($_) => 1 } @commands;

    # No translation is needed and none is done. sow, epic and ticket each ship
    # their own nine verbs - clone, create, discard, list, missing, move,
    # restore, show, update - so a documented tira.ticket.move resolves
    # directly. An earlier
    # draft translated a record.* form into the three, on the belief that the
    # verbs are shared on disk. They are shared in the CLI and in the
    # documentation, not in the filesystem, and a guard carrying complexity
    # nobody can justify is a guard nobody trusts to be right.

    my %named;
    for my $document (qw(SKILLS.md docs/commands.md docs/POLICIES.md)) {
        open my $fh, '<', $document or die "$document: $!";
        my $text = do { local $/; <$fh> };
        close $fh;
        while ( $text =~ /\b(tira\.[a-z][a-z0-9._-]*)/g ) {
            ( my $name = $1 ) =~ s/[.-]+\z//;
            push @{ $named{$name} }, $document;
        }
    }

    my @unrunnable = sort grep { !$ships{$_} } keys %named;
    is_deeply( \@unrunnable, [],
        'every command the documents name resolves to something that ships' );
}

done_testing;

__END__

=head1 NAME

03-metadata.t - Repository metadata and POD gate for Tira

=head1 DESCRIPTION

Ensures the required repository artifacts exist, version metadata agrees, and
every shipped Perl module, command, and test contains valid POD.

=head2 What this file no longer checks

The count of police rules stated in the documentation. Until 4.76 that lived
here as a match on C<< /(\d+) rules cover/ >> - one phrasing of a sentence that
appears in three places, so the two stated differently were never read and one
of them sat four rules behind. It moved to
F<t/433-a-count-stated-three-times-and-checked-once.t>, which matches the shape
of a claim rather than a sentence, and it is not duplicated back here: two
checks of one fact is what produced the drift.

The rule I<names> are still checked here, against F<docs/POLICIES.md>, because
that is a different question - whether a rule shipped without being documented -
and it is answered by name rather than by arithmetic.

=cut
