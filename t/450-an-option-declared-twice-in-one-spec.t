#!/usr/bin/env perl
# TKT-775. sub run's @spec array, passed whole to GetOptionsFromArray on
# every command, declared 'attach=s@' twice (lines 326 and 407, both
# pointing at the same destination). Getopt::Long prints "Duplicate
# specification ... for option ..." straight to STDERR - not through
# warn(), so the $SIG{__WARN__} capture around the GetOptionsFromArray
# call never sees it - on every single invocation of the raw entrypoint.
# Harmless (both entries share a destination, so parsing still succeeds),
# but unconditional noise and a confusing read of @spec for anyone
# auditing what --attach actually does.
#
# This test reads @spec directly from the source rather than exercising
# Getopt::Long at runtime: Tira::CLI->run(), invoked the way the test
# suite calls it, does not reproduce the STDERR line the same way the raw
# entrypoint script does, so a source-level check is what actually pins
# the fix - no option name should be declared twice in @spec, whatever
# the runtime path used to reach it.

use strict;
use warnings;

use File::Spec;
use FindBin qw($Bin);
use Test::More;

my $cli_pm = File::Spec->catfile( $Bin, '..', 'lib', 'Tira', 'CLI.pm' );
open my $fh, '<', $cli_pm or die "can't read $cli_pm: $!";
local $/;
my $source = <$fh>;
close $fh;

$source =~ /my \@spec = \((.*?)\n\s*\);\n/s
  or die "couldn't find the \@spec array literal in $cli_pm - has sub run changed shape?";
my $spec_body = $1;

my @option_names;
while ( $spec_body =~ /'([^']+)'\s*=>\s*\\\$option\{/g ) {
    push @option_names, $_ for split /\|/, $1;
}

ok( scalar(@option_names) > 50, 'sanity: the spec literal was actually found and parsed (' . scalar(@option_names) . ' option names)' );

my %seen;
my @duplicates = grep { $seen{$_}++ } @option_names;

is_deeply( \@duplicates, [], 'no option name is declared twice in @spec - Getopt::Long would otherwise print "Duplicate specification" to STDERR on every invocation' );

done_testing();

__END__

=head1 NAME

t/450-an-option-declared-twice-in-one-spec.t - sub run's Getopt::Long spec
never declares the same option name twice

=head1 DESCRIPTION

C<'attach=s@'> appeared twice in C<@spec> (TKT-775), both pointing at the
same destination, so parsing still worked - but Getopt::Long's own
duplicate-specification warning bypasses the C<$SIG{__WARN__}> capture
built around the C<GetOptionsFromArray> call and prints straight to
STDERR on every command. Fixed by removing the redundant entry. This test
parses C<@spec>'s source text directly, since C<Tira::CLI-E<gt>run()>
invoked the way the test suite calls it does not reproduce the STDERR
line the way the raw entrypoint script does - a source-level duplicate
check is what actually pins the fix, and it also guards every other
option name in the same array, not just C<--attach>.

=cut
