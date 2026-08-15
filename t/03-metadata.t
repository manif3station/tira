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
like( $env_text, qr/^VERSION=1\.98$/m, '.env stores version 1.98' );

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
    'Concurrency and transaction semantics', '100 use cases',
) {
    like( $skills_text, qr/^## \Q$section\E$/m, "SKILLS.md contains $section" );
}
my @use_cases = $skills_text =~ /^### UC-\d{3}:/mg;
is( scalar @use_cases, 136, 'SKILLS.md contains exactly 136 numbered use cases' );
my %seen;
while ( $skills_text =~ /^### UC-(\d{3}):/mg ) {
    $seen{$1}++;
}
is_deeply( [ sort keys %seen ], [ map { sprintf '%03d', $_ } 1 .. 136 ], 'use cases are numbered UC-001 through UC-136' );
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
is( $Tira::VERSION, '1.98', 'and the release being made is the one intended' );

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
# says so - SKILLS.md claimed twenty while twenty-two shipped. Every rule is
# also named in the policies guide, so a rule added without being documented is
# caught by name rather than by arithmetic.
my $rules = Tira->new->policy_rules;
my ($claimed) = $skills_text =~ /(\d+) rules cover/;
is( $claimed, scalar @{$rules}, 'SKILLS.md says how many rules there really are' );

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

my @undocumented;
for my $command (@commands) {
    my $dotted = $command;
    $dotted =~ s{\Acli/}{};
    $dotted =~ s{/cli/}{/};

    # The dispatcher drops every 'skills' segment, so the command an agent
    # types is not the path the file sits at. Deriving it any other way
    # invents commands that do not exist and then reports them missing.
    $dotted = join '.', grep { $_ ne 'skills' } split m{/}, $dotted;
    $dotted = "tira.$dotted";

    # The three record boards share one set of verbs, documented once.
    next if $dotted =~ /\Atira\.(?:sow|epic|ticket)\./;
    next if $dotted =~ /\Atira\.dashboard\./;
    push @undocumented, $dotted if index( $documented, $dotted ) < 0;
}
is_deeply( \@undocumented, [],
    'every command that ships is named in a document an agent reads' );

is( scalar @commands, 143, 'release ships exactly 143 executable CLI entrypoints' );

done_testing;

__END__

=head1 NAME

03-metadata.t - Repository metadata and POD gate for Tira

=head1 DESCRIPTION

Ensures the required repository artifacts exist, version metadata agrees, and
every shipped Perl module, command, and test contains valid POD.

=cut
