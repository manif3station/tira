#!/usr/bin/env perl
# TKT-1129. run_due_job hands a command-mode job's argv straight to
# IPC::Open3::open3 with no path resolution of its own - it relies entirely
# on the served board process's OWN ambient $ENV{PATH} and current working
# directory at the exact moment the job fires. A bare word like 'd2' whose
# only real home is beside the running perl interpreter itself (a typical
# local::lib install - d2 sits in the same bin/ as perl) fails with ENOENT
# whenever the process's cwd has drifted to a directory with no matching
# relative PATH entry - which the reporting incident hit live: a served
# board's cwd happened to be an unrelated project's subdirectory when
# JOB-008 fired.
#
# WRITTEN RED.

use strict;
use warnings;

use Cwd ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
require Tira::CLI::Police::Jobs;

my $tmp = tempdir( CLEANUP => 1 );

# A fake perl interpreter and, beside it, the fake tool the job wants to run -
# the exact shape a local::lib install of $^X and its sibling scripts takes.
my $fake_bin_dir = File::Spec->catdir( $tmp, 'fake-perl-bin' );
mkdir $fake_bin_dir or die $!;
my $fake_perl = File::Spec->catfile( $fake_bin_dir, 'perl' );
my $fake_tool = File::Spec->catfile( $fake_bin_dir, 'mytool-1129' );
for my $exe ( $fake_perl, $fake_tool ) {
    open my $fh, '>', $exe or die $!;
    print {$fh} "#!/bin/sh\nexit 0\n";
    close $fh;
    chmod 0755, $exe;
}

# Nowhere with a relative match, and $ENV{PATH} deliberately excludes the
# fake bin dir entirely - the process's own PATH/cwd give no way to find
# the tool, the same way the reporting incident's PATH/cwd combination
# gave none for 'd2'.
my $elsewhere = File::Spec->catdir( $tmp, 'elsewhere' );
mkdir $elsewhere or die $!;
my $real_cwd = Cwd::getcwd();
chdir $elsewhere or die $!;

my $job = { mode => 'command', command => 'mytool-1129' };
my $result = do {
    local $ENV{PATH} = '/nonexistent-1129-a:/nonexistent-1129-b';
    local $^X        = $fake_perl;
    Tira::CLI::Police::Jobs::run_due_job( job => $job );
};

chdir $real_cwd or die $!;

is( $result->{status}, 0,
    "a bare command beside \$^X's own bin dir still execs, even when cwd and \$ENV{PATH} give no other way to find it" )
  or diag( "output: " . ( $result->{output} // '(none)' ) );

# --- an already-absolute command word is unaffected - no regression --------

{
    my $job2 = { mode => 'command', command => $fake_tool };    # already absolute
    my $result2 = do {
        local $ENV{PATH} = '/nonexistent-1129-a:/nonexistent-1129-b';
        local $^X        = $fake_perl;
        Tira::CLI::Police::Jobs::run_due_job( job => $job2 );
    };
    is( $result2->{status}, 0, 'an already-absolute command word execs exactly as before' )
      or diag( "output: " . ( $result2->{output} // '(none)' ) );
}

# --- a bare word found on an ABSOLUTE $ENV{PATH} entry is unaffected -------

{
    my $job3 = { mode => 'command', command => 'mytool-1129' };
    my $result3 = do {
        local $ENV{PATH} = "/nonexistent-1129-c:$fake_bin_dir";    # absolute entry, no beside-$^X match needed
        local $^X        = '/usr/bin/perl';                        # deliberately NOT beside the fake bin dir
        Tira::CLI::Police::Jobs::run_due_job( job => $job3 );
    };
    is( $result3->{status}, 0, 'a bare word still resolves via a genuine absolute PATH entry' )
      or diag( "output: " . ( $result3->{output} // '(none)' ) );
}

# --- a RELATIVE $^X (Perl promises nothing more) never causes a wrong or --
# --- cwd-dependent resolution - it falls through safely instead (Codex) ---

{
    my $job4    = { mode => 'command', command => 'mytool-1129' };
    my $result4 = do {
        local $ENV{PATH} = "/nonexistent-1129-d:$fake_bin_dir";    # the only real way to find it
        local $^X        = 'perl';                                 # relative on purpose - a bare word
        Tira::CLI::Police::Jobs::run_due_job( job => $job4 );
    };
    is( $result4->{status}, 0,
        'a relative $^X does not defeat resolution - the absolute PATH fallback still finds it' )
      or diag( "output: " . ( $result4->{output} // '(none)' ) );
}

done_testing;

__END__

=head1 NAME

1152-a-command-that-worked-from-a-terminal-and-nowhere-else.t -
run_due_job resolves a bare command beside $^X's own bin, not only via
the process's ambient PATH/cwd

=head1 DESCRIPTION

TKT-1129. C<run_due_job> used to hand a command-mode job's argv straight
to C<IPC::Open3::open3> with no resolution of its own, so a bare word
like C<d2> - whose real, reliable location is beside the running perl
interpreter itself in a typical C<local::lib> install - depended entirely
on the served board process's own ambient C<$ENV{PATH}> and current
working directory at the moment the job fired. Reported live: a served
board's cwd had drifted to an unrelated project's subdirectory, and the
job failed with C<ENOENT> even though the identical command worked
perfectly typed at a terminal.

=cut
