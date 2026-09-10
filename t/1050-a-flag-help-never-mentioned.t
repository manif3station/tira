#!/usr/bin/env perl

# TKT-1050. Michael, TG msg #8002: "have you fixed that yet? i still seeing
# --with-p* not there" - d2 tira.dashboard --help never listed
# --with-police (TKT-897) or --with-policy-bridge (TKT-1026), though both
# are real, working GetOptions flags (lib/Tira/CLI.pm), because --help's
# usage line is read literally off SKILLS.md's own "tira.dashboard ..."
# line, and that line was never updated when either flag was added.
#
# Checked a little more generally than these two flags by name - every
# 'with-po...' flag GetOptions declares must appear on the usage line, so a
# third one sharing that prefix fails this the same way. Not every with-*
# flag: --with-level and --with-questions share the same global option
# table but belong to other commands, and a scan wide enough to catch them
# would wrongly demand dashboard's usage line list flags it does not take.

use strict;
use warnings;

use File::Spec;
use Test::More;

my $root = File::Spec->rel2abs('.');

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

my $cli_source    = slurp( File::Spec->catfile( $root, 'lib', 'Tira', 'CLI.pm' ) );
my $skills_source = slurp( File::Spec->catfile( $root, 'SKILLS.md' ) );

# Scoped to 'with-po...' on purpose, not every with-* flag GetOptions
# declares: --with-level (a stale/dwell.report flag) and --with-questions
# (list output, no dashboard-only meaning) share the same global option
# table with dashboard's own --with-police/--with-policy-bridge, and
# neither belongs on dashboard's usage line - a genuinely general scan
# would wrongly demand SKILLS.md list them there too. Codex-caught: an
# earlier version of this comment claimed "every --with-* flag", which
# was already false the moment --with-questions existed; the check itself
# was always this narrow, only the claim about it was wrong.
my @declared = $cli_source =~ /'(with-po\w[\w-]*)'\s*=>\s*\\\$option\{with_po\w+\}/g;
ok( scalar @declared >= 2, 'found dashboard\'s own --with-* flags declared in lib/Tira/CLI.pm' )
  or BAIL_OUT('nothing to check this against');

my ($usage_line) = $skills_source =~ /^tira\.dashboard\s+(\S.*)$/m;
ok( defined $usage_line, 'SKILLS.md has a usage line for tira.dashboard' )
  or BAIL_OUT('nothing to check the flags against');

my @missing = grep { $usage_line !~ /--\Q$_\E\b/ } @declared;
is_deeply( \@missing, [],
    'every --with-* flag dashboard actually accepts is named in its own SKILLS.md usage line, so --help shows it too' );

done_testing();

__END__

=head1 NAME

t/1050-a-flag-help-never-mentioned.t - every real dashboard flag must appear
in its own SKILLS.md usage line, or --help never shows it

=head1 DESCRIPTION

TKT-1050: C<--with-police> and C<--with-policy-bridge> are both real,
working GetOptions flags for C<tira.dashboard> (lib/Tira/CLI.pm), but
C<d2 tira.dashboard --help> never listed either - reported live by Michael.
C<Tira::CLI::Usage>'s C<--help> reads its usage line literally off
SKILLS.md's own C<tira.dashboard ...> line, and that line was never updated
when either flag was added, so a real, working flag was invisible to
anyone reading only C<--help>.

Checked a little more generally than these two flags by name: every
C<with-po...> flag C<lib/Tira/CLI.pm> declares must be named in SKILLS.md's
usage line for dashboard, so a third one sharing that prefix fails this
test rather than needing its own card. Not every C<--with-*> flag -
C<--with-level> and C<--with-questions> share the same global option table
but belong to other commands, and a wider scan would wrongly demand
dashboard's usage line list flags it does not take.

=cut
