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

my $failed = 0;
for my $script (@entrypoints) {
    my $output = `$^X -c -Ilib "$script" 2>&1`;
    my $ok = $? == 0;
    $failed++ if !$ok;
    diag("$script does not compile:\n$output") if !$ok;
}
is( $failed, 0, 'every entrypoint compiles' );

# --- and reaches a handler ------------------------------------------------------
#
# A script that parses and dispatches to something Tira::CLI has never heard of
# is a doorway into a wall, and it fails in front of whoever typed it. There is
# no registry to compare against, so the question is asked the only honest way:
# run the command and see whether the answer is "unsupported".
#
# Every other failure is fine here. A command that wants a card it has not been
# given is working correctly; this is only about whether anything is listening.

my @unheard;
for my $script (@entrypoints) {
    open my $handle, '<', $script or die "Cannot read $script: $!";
    my $body = do { local $/; <$handle> };
    close $handle;

    # The dispatcher derives its command from its own path when the script does
    # not say one, and that derivation is exercised by the commands that do run.
    # Only the ones naming it out loud can be asked here.
    my ($named) = $body =~ /command\s*=>\s*'([a-z][a-z0-9._-]*)'/;
    next if !defined $named;

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        eval { Tira::CLI->run( command => $named, argv => [] ); 1 };
    }
    push @unheard, "$script names $named" if ( $out . $err ) =~ /Unsupported Tira command/;
}
is_deeply( \@unheard, [],
    'every entrypoint that names its command reaches something that handles it' );

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
