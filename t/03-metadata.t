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
like( $env_text, qr/^VERSION=0\.29$/m, '.env stores version 0.29' );

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
is( scalar @use_cases, 100, 'SKILLS.md contains exactly 100 numbered use cases' );
my %seen;
while ( $skills_text =~ /^### UC-(\d{3}):/mg ) {
    $seen{$1}++;
}
is_deeply( [ sort keys %seen ], [ map { sprintf '%03d', $_ } 1 .. 100 ], 'use cases are numbered UC-001 through UC-100' );
unlike( $skills_text, qr{/home/[A-Za-z0-9._-]+/}, 'SKILLS.md contains no hard-coded home-directory path' );
unlike( $skills_text, qr/--project|TIRA_HOME|\.tira\/|project selector/i, 'SKILLS.md does not disclose project location or selectors' );

use lib 'lib';
use Tira;
is( $Tira::VERSION, '0.29', 'module version matches .env' );
unlike( $skills_text, qr/\bSpecified\b/i, 'every documented command and use case is implemented' );

my @perl_files = ( 'lib/Tira.pm', 'lib/Tira/CLI.pm' );
find( { no_chdir => 1, wanted => sub {
    return if !-f $File::Find::name;
    return if $File::Find::name !~ m{(?:\A|/)cli/[^/]+\z} && $File::Find::name !~ m{\At/.*\.t\z};
    $File::Find::name =~ /\A([^\x00-\x1f\x7f]+)\z/ or die 'Unsafe Perl file path';
    push @perl_files, $1;
} }, qw(cli skills t) );
for my $file (@perl_files) {
    is( podchecker($file), 0, "$file has valid POD" );
}
my @commands = grep { m{(?:\A|/)cli/[^/]+\z} && -x $_ } @perl_files;
is( scalar @commands, 83, 'release ships exactly 83 executable CLI entrypoints' );

done_testing;

__END__

=head1 NAME

03-metadata.t - Repository metadata and POD gate for Tira

=head1 DESCRIPTION

Ensures the required repository artifacts exist, version metadata agrees, and
every shipped Perl module, command, and test contains valid POD.

=cut
