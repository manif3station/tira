#!/usr/bin/env perl
# Every script this skill ships compiles, and dispatches to a command that
# exists.
#
# On 2026-08-13 both backup entrypoints shipped as Perl syntax errors and the
# whole suite stayed green. 131 files, 4306 tests, 100 percent statement and
# subroutine coverage on all three modules - and the two commands an agent would
# type did not run at all. A shell heredoc had eaten the backslashes, so they
# said "unshift \@INC" and perl refused them.
#
# Nothing caught it because nothing runs these scripts. Every test calls
# Tira::CLI directly; exactly one executes an entrypoint, and it is cli/usage.
# So the code the scripts delegate to is measured to the last statement, and the
# doorway into it is not measured at all - which is the same second-order fault
# this project keeps finding in itself: the thing being measured is not the
# thing being shipped.
#
# perl -c on every one of them costs seconds. There was never a cost argument.
#
# Dispatching matters as much as compiling. A script that compiles and names a
# command the dispatcher has never heard of is a doorway into a wall, and it
# fails in front of whoever typed it rather than here.

use strict;
use warnings;

use File::Find qw(find);
use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

# Found rather than listed. A list is a second place to remember, and the whole
# fault here is a thing nobody remembered to check.
my @entrypoints;
find(
    {
        no_chdir => 1,
        wanted   => sub {
            my $path = $File::Find::name;
            return if !-f $path;
            return if $path !~ m{(?:\A|/)cli/[^/]+\z};
            return if $^O ne 'MSWin32' && !-x $path;
            push @entrypoints, $path;
        },
    },
    'cli',
    'skills',
);
@entrypoints = sort @entrypoints;

ok( scalar @entrypoints > 100,
    'the skill ships the entrypoints this expects to find: ' . scalar @entrypoints );

# --- each one compiles ---------------------------------------------------------
#
# The check that was missing. perl -c loads the file and everything it requires
# and refuses anything it cannot parse.

# All of them inside one child, not one child each.
#
# Devel::Cover instruments every process the harness starts, and a fork from an
# instrumented process carries that cost - 138 of them took over six minutes
# under coverage against 2.3 seconds without, and drove the suite into the
# timeout added in 1.31. That is the timeout doing its job, on a check I added
# myself. Compiling a script has nothing to do with measuring what the suite
# covers, so the compiling happens in one plain child that the collector never
# touches, and this process reads the list of failures it prints.
my $checker = <<'CHECKER';
my $bad = 0;
for my $script (@ARGV) {
    my $said = `$^X -c -Ilib "$script" 2>&1`;
    next if $? == 0;
    $bad++;
    print "$script\n$said\n";
}
exit $bad ? 1 : 0;
CHECKER

my $complaints = do {
    local $ENV{PERL5OPT}              = '';
    local $ENV{HARNESS_PERL_SWITCHES} = '';
    open my $child, '-|', $^X, '-e', $checker, @entrypoints
      or die "cannot start the compiler: $!";
    local $/;
    <$child>;
};
my $failed = ( $complaints // '' ) =~ /\S/ ? 1 : 0;
diag($complaints) if $failed;
is( $failed, 0, 'every entrypoint compiles' );

# --- and names a command the dispatcher has heard of ----------------------------
#
# A script that parses and dispatches to something Tira::CLI does not handle is
# a doorway into a wall, and it fails in front of whoever typed it.
#
# Asked of the source rather than by running the command. The first version ran
# each one to see whether the answer was "unsupported", and that was wrong twice
# over: it took minutes under the coverage collector, and it ran real commands
# against whatever board the working directory resolved to - for tira.backup
# that means committing it. A test that asks "is anybody listening" must not
# also be heard. Textual, and it says so: it proves the name appears where
# commands are dispatched, not that the handler behind it is correct, which is
# what the rest of the suite is for.

my $dispatcher = do {
    open my $handle, '<', File::Spec->catfile(qw(lib Tira CLI.pm)) or die $!;
    local $/;
    <$handle>;
};

# How many of them were actually asked, so an empty result cannot mean an empty
# scan. Measured when this was added: 149 entrypoints found, 23 examined - the
# other 126 skipped by the guard below, for the reason its comment gives. If the
# pattern stopped matching, a quoting change in the entrypoints or different
# spacing around the fat comma, all 149 would skip and this file would go green
# having checked nothing at all.
#
# is_deeply(X, []) is satisfied by a collector that ran and by one that never
# ran, which is the fault t/147 guards for denials, in a positive assertion.
# Found by the bug hunt. TKT-341.
my $examined = 0;

my @unheard;
for my $script (@entrypoints) {
    open my $handle, '<', $script or die "Cannot read $script: $!";
    my $body = do { local $/; <$handle> };
    close $handle;

    # The dispatcher derives its command from its own path when the script does
    # not say one, and that derivation is exercised by every command that runs.
    # Only the ones naming it out loud can be asked here.
    my ($named) = $body =~ /command\s*=>\s*'([a-z][a-z0-9._-]*)'/;
    next if !defined $named;
    $examined++;
    push @unheard, "$script names $named"
      if $dispatcher !~ /\Q'$named'\E/;
}
# A real floor rather than a token greater-than-zero: twenty of them named a
# command when this was written, and a change that halved that is worth knowing
# about even if nothing here fails.
cmp_ok( $examined, '>=', 20,
    "the scan examined $examined entrypoints, so an empty result below means "
      . 'nothing wrong rather than nothing looked at' );

is_deeply( \@unheard, [],
    'every entrypoint that names its command names one the dispatcher handles' );

done_testing;

__END__

=head1 NAME

131-every-command-an-agent-types-runs.t - every shipped entrypoint compiles

=head1 DESCRIPTION

Two entrypoints shipped as syntax errors while the suite passed with full
coverage, because every test calls C<Tira::CLI> directly and almost nothing
executes the scripts the skill ships. The code behind the doorway was measured
to the last statement; the doorway was not measured at all.

Every executable under F<cli> and F<skills> is now found, compiled, and checked
to name a command the dispatcher knows.

=cut
