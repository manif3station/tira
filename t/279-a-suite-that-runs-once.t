#!/usr/bin/env perl
# A release ran the suite twice, on the same tree, and the second run cost
# five hours it did not need to.
#
# Measured on one release: the gate ran the full suite and passed - 258
# files, 6072 tests, 100.0 on all three modules - and the push hook then ran
# the identical suite against the identical tree, because only one test
# container may run at a time and the hook has no way to know the gate
# already proved this tree. Six cards and five releases queued behind it from
# 19:44 past midnight, and three attempts were killed at a ceiling that had to
# be raised before any could finish - every one of them a second run of
# something already proved.
#
# The hook was not wrong to distrust a claim: "I ran it and it passed" is a
# sentence, and a gate that accepts sentences is not a gate. What it can trust
# is a record naming the exact tree it tested, in git's own tree hash - the
# same hash git computes from the actual blob contents, which nobody can
# produce for a tree they never had. tools/gate-cache-write records a pass
# that way; tools/gate-cache-read is the only thing that reads it, and it
# rejects anything that does not match the tree HEAD carries right now, or
# that has gone stale, or that is simply not there.
#
# tools/gate-run runs the suite and coverage against a checkout of HEAD -
# never the desk - and writes the record only on a real pass at 100% coverage.
#
# TKT-680 changed why this file's title is true. Until 4.62 the push hook ran
# the suite too, and the record was what stopped the second run repeating the
# first; the hook consulted it and, on anything short of an exact fresh match,
# ran the suite exactly as it always had. Since 4.62 the hook runs no suite at
# all, so there is no second run for a record to prevent - the suite runs once
# because only one place runs it. The assertions below were rewritten to that
# mechanism and now guard it from both directions, because two denials about
# the hook would also pass against a repository where NOTHING runs the suite,
# which is a worse state than the one this file was written about.

use strict;
use warnings;

use File::Spec;
use File::Path ();
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Run qw(run_quietly run_capturing run_split);
use Tira::CLI;
# Tira::CLI::Serve holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Serve;

plan skip_all => 'git is not installed here' if !Tira::CLI::Serve::_program_exists('git');

my $root = File::Spec->rel2abs('.');

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

# --- the tools exist and are runnable ---------------------------------------

for my $tool (qw(gate-cache-write gate-cache-read gate-run)) {
    my $path = File::Spec->catfile( $root, 'tools', $tool );
    ok( -f $path, "tools/$tool ships in the repository" );
    ok( -x $path, "tools/$tool is executable" );
}

# --- the suite runs once, and since 4.62 for a stronger reason --------------
#
# This file was written when BOTH the verify column and the push hook ran the
# suite, and the record was what stopped the second run repeating the first.
# TKT-680 removed the suite from the hook entirely, so there is no second run
# to prevent: one place runs it, and the record is what that place leaves
# behind for a person who wants to know whether a tree was already proved.
#
# The assertions changed with the mechanism rather than being deleted, because
# the property this file is named for - the suite runs once - is still the
# subject, and it is now guarded from both directions.

my $hook_source = slurp( File::Spec->catfile( $root, 'tools', 'hooks', 'pre-push' ) );

# Established before it is denied. Both statements about the hook below are
# denials now, where they used to be assertions, and a denial about a file that
# failed to load passes while measuring nothing - t/147 caught this here.
like( $hook_source, qr{\A#!/usr/bin/env bash},
    'the push hook is a bash script and was read' );

unlike( $hook_source, qr/gate-cache-read/,
    'the hook no longer consults the record, because it runs no suite to skip' );
unlike( $hook_source, qr/\bprove\s+-lr\b/,
    'and runs no suite, so there is no second run for a record to prevent' );

my $runner_source = slurp( File::Spec->catfile( $root, 'tools', 'gate-run' ) );
like( $runner_source, qr/\bprove\s+(?:-j\S+\s+)?-lr\b/,
    'the one place that runs the suite still runs it' );
like( $runner_source, qr/gate-cache-write/,
    'and records the pass, so what proved a tree survives the run that proved it' );

# --- a throwaway repository, so tree hashes can be manufactured cheaply -----
#
# Building a real git history here rather than asserting against strings,
# because the property under test - "the agent cannot forge it without
# producing the tree it claims to have tested" - is a claim about git's own
# hashing, and the only way to know these tools agree with git is to ask git.

my $tmp   = tempdir( CLEANUP => 1 );
my $repo  = File::Spec->catdir( $tmp, 'skills', 'faketira' );
my $tools = File::Spec->catdir( $repo, 'tools' );
mkdir File::Spec->catdir( $tmp, 'skills' ) or die $!;
mkdir $repo  or die $!;
mkdir $tools or die $!;

# The scratch repo needs the modules gate-run will hold to 100%. Since TKT-594
# it derives that list by walking lib/ rather than naming three paths, so a
# fake repo with no lib/ is a repo it now refuses outright - correctly, since a
# gate that finds no modules and passes is the fault that card removed. The
# files are empty: nothing reads them, the coverage figures come from the
# mocked docker below, and what matters is that the names on disk are the names
# the mock reports.
my $fake_lib = File::Spec->catdir( $repo, 'lib', 'Tira' );
File::Path::make_path($fake_lib) or die $! if !-d $fake_lib;
for my $module ( 'lib/Tira.pm', 'lib/Tira/CLI.pm', 'lib/Tira/DashboardWeb.pm',
    'lib/Tira/OnboardWeb.pm' ) {
    open my $fh, '>', File::Spec->catfile( $repo, split m{/}, $module ) or die $!;
    print {$fh} "1;\n";
    close $fh;
}

# gate-run looks two directories up from tools/ for the compose file, so the
# scratch tree mirrors that shape. Its content is never read - docker is
# mocked below - only its presence is checked.
open my $compose, '>', File::Spec->catfile( $tmp, 'docker-compose.testing.yml' ) or die $!;
print {$compose} "services: {}\n";
close $compose;

for my $tool (qw(gate-cache-write gate-cache-read gate-run)) {
    my $from = File::Spec->catfile( $root, 'tools', $tool );
    my $to   = File::Spec->catfile( $tools, $tool );
    open my $in,  '<', $from or die $!;
    open my $out, '>', $to   or die $!;
    print {$out} do { local $/; <$in> };
    close $in;
    close $out;
    chmod 0755, $to or die $!;
}

is( run_quietly( 'git', 'init', '-q', $repo ), 0, 'a throwaway repository to test the tree hashing against' );
for my $setting ( [ 'user.email', 'nobody@example.invalid' ], [ 'user.name', 'Nobody' ] ) {
    run_quietly( 'git', '-C', $repo, 'config', @{$setting} );
}

open my $tracked, '>', File::Spec->catfile( $repo, 'tracked-file' ) or die $!;
print {$tracked} "version one\n";
close $tracked;
run_quietly( 'git', '-C', $repo, 'add', '-A' );
run_quietly( 'git', '-C', $repo, 'commit', '-q', '-m', 'first commit' );

my $bin = File::Spec->catdir( $tmp, 'bin' );
mkdir $bin or die $!;
local $ENV{PATH} = "$bin:$ENV{PATH}";

sub tree_hash {
    my ( undef, $out ) = run_capturing( 'git', '-C', $repo, 'rev-parse', 'HEAD^{tree}' );
    chomp $out;
    return $out;
}

sub cache_dir {
    my ( undef, $common ) = run_capturing( 'git', '-C', $repo, 'rev-parse', '--git-common-dir' );
    chomp $common;
    $common = File::Spec->rel2abs( $common, $repo );
    return File::Spec->catdir( $common, 'tira-gate-cache' );
}

sub in_repo {
    my ($code) = @_;
    my $prev = File::Spec->rel2abs('.');
    chdir $repo or die $!;
    my @result = $code->();
    chdir $prev or die $!;
    return @result;
}

sub cache_read {
    return in_repo( sub { return run_split( File::Spec->catfile( $tools, 'gate-cache-read' ) ) } );
}

sub cache_write {
    my ($outfile) = @_;
    return in_repo( sub {
        return run_split( File::Spec->catfile( $tools, 'gate-cache-write' ), $outfile );
    } );
}

sub run_gate {
    return in_repo( sub { return run_split( File::Spec->catfile( $tools, 'gate-run' ) ) } );
}

# --- nothing recorded yet: a miss -------------------------------------------

{
    my ( $status, $out ) = cache_read();
    isnt( $status, 0, 'with nothing recorded, the read is a miss' );
    is( $out, '', 'and nothing is printed to stand in for a suite run' );
}

# --- a real record, written for this exact tree -----------------------------

my $passing_output = <<'EOF';
All tests successful.
Files=258, Tests=6072, 700 wallclock secs
Result: PASS
lib/Tira.pm               100.0  100.0  100.0
lib/Tira/CLI.pm           100.0  100.0  100.0
lib/Tira/DashboardWeb.pm  100.0  100.0  100.0
lib/Tira/OnboardWeb.pm    100.0  100.0  100.0
Total                     100.0  100.0  100.0
EOF

my $first_tree = tree_hash();

{
    my $outfile = File::Spec->catfile( $tmp, 'suite-output' );
    open my $fh, '>', $outfile or die $!;
    print {$fh} $passing_output;
    close $fh;

    my ($status) = cache_write($outfile);
    is( $status, 0, 'writing a record for the current tree succeeds' );
}

{
    my ( $status, $out ) = cache_read();
    is( $status, 0, 'and reading it back for the SAME tree is a hit' );
    like( $out, qr/Result: PASS/, 'carrying the recorded suite output' );
    like( $out, qr/100\.0\s+100\.0\s+100\.0/, 'coverage included, unmodified' );
    unlike( $out, qr/^tree=/m, 'the header naming the tree is not itself part of what a hit prints' );
}

# --- any edit changes the hash, and the old record no longer answers -------

{
    open my $fh, '>', File::Spec->catfile( $repo, 'tracked-file' ) or die $!;
    print {$fh} "version two\n";
    close $fh;
    run_quietly( 'git', '-C', $repo, 'add', '-A' );
    run_quietly( 'git', '-C', $repo, 'commit', '-q', '-m', 'a real edit' );

    my $second_tree = tree_hash();
    isnt( $second_tree, $first_tree, 'the edit really did change the tree hash' );

    my ( $status, $out ) = cache_read();
    isnt( $status, 0, 'so the record for the OLD tree does not answer for the new one' );
    is( $out, '', 'nothing is printed for it' );
}

# --- a record naming a different tree than the one it is filed under -------
#
# The property this whole card rests on: forging a hit means either producing
# a tree that hashes to the target, or writing a record whose own claimed tree
# does not match where it is filed. This is the second one, made directly -
# the shape corruption or a copy-paste mistake would actually take.

{
    my $dir     = cache_dir();
    my $current = tree_hash();

    open my $fh, '>', File::Spec->catfile( $dir, $current ) or die $!;
    print {$fh} "tree=not-the-real-tree-hash\nat=2026-08-18T20:00:00Z\n$passing_output";
    close $fh;

    my ( $status, $out ) = cache_read();
    isnt( $status, 0,
        'a record filed under this tree but CLAIMING a different one is rejected, not trusted because the filename matched' );
    is( $out, '', 'nothing is printed for it' );

    unlink File::Spec->catfile( $dir, $current );
}

# --- staleness: a genuine match, recorded too long ago ----------------------

{
    my $dir     = cache_dir();
    my $current = tree_hash();

    open my $fh, '>', File::Spec->catfile( $dir, $current ) or die $!;
    print {$fh} "tree=$current\nat=2020-01-01T00:00:00Z\n$passing_output";
    close $fh;

    local $ENV{GATE_CACHE_MAX_AGE} = 60;
    my ( $status, $out ) = cache_read();
    isnt( $status, 0, 'a record for the right tree, filed years ago, is too old to trust' );
    is( $out, '', 'nothing is printed for it' );

    unlink File::Spec->catfile( $dir, $current );
}

# --- proof by deleting the record: the fallback is real, not assumed -------

{
    my $outfile = File::Spec->catfile( $tmp, 'suite-output-2' );
    open my $fh, '>', $outfile or die $!;
    print {$fh} $passing_output;
    close $fh;
    cache_write($outfile);

    my ($hit_status) = cache_read();
    is( $hit_status, 0, 'a freshly written record for the current tree is a hit' );

    unlink File::Spec->catfile( cache_dir(), tree_hash() );

    my ( $miss_status, $out ) = cache_read();
    isnt( $miss_status, 0, 'and deleting it is what makes the difference - the read falls back to a miss' );
    is( $out, '', 'nothing stands in for the suite that would now have to run' );
}

# --- gate-run refuses a dirty tree before it ever reaches docker ------------
#
# It tests the commit the hook is about to check out, the same one the hook
# itself judges - not the desk. Recording a pass for anything else would be
# recording a pass for a tree nobody is pushing.

{
    open my $fh, '>', File::Spec->catfile( $repo, 'tracked-file' ) or die $!;
    print {$fh} "an uncommitted change\n";
    close $fh;

    my ( $status, undef, $err ) = run_gate();

    isnt( $status, 0, 'gate-run refuses to test a tree with uncommitted changes sitting on top of it' );
    like( $err, qr/commit first/i, 'and says why' );

    run_quietly( 'git', '-C', $repo, 'checkout', '--', 'tracked-file' );
}

# --- gate-run, run for real, writes the record only on a real pass ---------
#
# docker is mocked, the same way tools/prove-the-gate mocks it: a script on
# PATH that prints canned suite output instead of running a container. What
# is proved here is gate-run's own judgement about what it is told, and that
# it writes nothing when the answer is not a clean pass.

sub install_fake_docker {
    my ($suite_output) = @_;
    my $docker = File::Spec->catfile( $bin, 'docker' );
    open my $out, '>', $docker or die $!;
    print {$out} "#!/usr/bin/env bash\ncat <<'SUITE_EOF'\n$suite_output\nSUITE_EOF\n";
    close $out;
    chmod 0755, $docker or die $!;
    return;
}

{
    install_fake_docker($passing_output);

    my ($status) = run_gate();
    is( $status, 0, 'gate-run passes end to end against a mocked docker that reports a clean suite' );

    my ($read_status) = cache_read();
    is( $read_status, 0, 'and the record it wrote is what a read now finds' );

    unlink File::Spec->catfile( cache_dir(), tree_hash() );
}

{
    my $failing_output = <<'EOF';
Failed 3/300 subtests
Result: FAIL
EOF
    install_fake_docker($failing_output);

    my ($status) = run_gate();
    isnt( $status, 0, 'and a suite that failed makes gate-run fail too' );

    my ($read_status) = cache_read();
    isnt( $read_status, 0, 'with no record written for it - a failure is not cached as a pass' );
}

{
    my $partial_coverage = <<'EOF';
All tests successful.
Result: PASS
lib/Tira.pm               98.0  100.0  99.0
lib/Tira/CLI.pm           100.0  100.0  100.0
lib/Tira/DashboardWeb.pm  100.0  100.0  100.0
lib/Tira/OnboardWeb.pm    100.0  100.0  100.0
EOF
    install_fake_docker($partial_coverage);

    my ($status) = run_gate();
    isnt( $status, 0, 'a suite that passed with coverage under 100% is not a pass gate-run will record' );

    my ($read_status) = cache_read();
    isnt( $read_status, 0, 'nothing was written for it' );
}

done_testing;

__END__

=head1 NAME

279-a-suite-that-runs-once.t - TKT-351

=head1 DESCRIPTION

A release ran the full suite twice - once by hand, once by the push hook -
because the hook had no way to trust a claim that the tree it was about to
push was already proved. C<tools/gate-run> tests a checkout of HEAD and, on a
real pass at 100% coverage, records it under git's own tree hash;
C<tools/gate-cache-read> answers a hit only for that exact tree, recently
enough to trust.

Since 4.62 (TKT-680) the push hook runs no suite at all, so the double run it
was built to prevent cannot happen: the suite runs once because only
C<tools/gate-run> runs it, and nothing consults the record automatically. The
assertions here guard that from both directions - the hook must run no suite
and consult no record, and the runner must still run the suite and still write
the record. Denials about the hook alone would pass against a repository where
nothing runs the suite, which is worse than the state this file was written
about.

=cut
