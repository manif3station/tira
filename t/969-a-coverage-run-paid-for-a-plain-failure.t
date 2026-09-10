#!/usr/bin/env perl

# TKT-969. Measured 2026-09-06: an identical suite costs 86 seconds plain and
# 788-801 under Devel::Cover - roughly a nine-fold multiplier - and three of
# six gate attempts that day failed on a PLAIN suite failure, each paying the
# full instrumented run to learn what an 86-second plain run would have said
# just as well. TKT-947's gate was killed six times under load the same
# evening; the plain suite still finished in 179s where the instrumented run
# could not finish at all.
#
# The fix: tools/gate-run's embedded container script runs the suite plain
# FIRST, with no HARNESS_PERL_SWITCHES. A plain failure refuses immediately,
# via the same tools/gate-summarize a coverage-run failure already uses, and
# never touches Devel::Cover at all. A plain pass falls through into the
# existing coverage pass and its retry-on-collision loop, entirely unchanged.
#
# Tested by extracting the exact script text gate-run hands to `bash -lc`
# (the same text a real container executes) and running it directly against
# a scratch git checkout with stub `prove`/`cpanm`/`nproc`/`cover` and the
# real tools/gate-summarize, tools/coverage-complete and tools/coverage-guard
# copied in - this is the real logic under test, not a paraphrase of it, and
# needs no Docker daemon to prove.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $root = File::Spec->rel2abs('.');

sub extract_embedded_script {
    my ($gate_run_path) = @_;
    open my $fh, '<', $gate_run_path or die $!;
    my @lines = <$fh>;
    close $fh;
    my ( $start, $end );
    for my $i ( 0 .. $#lines ) {
        $start = $i, next if !defined $start && $lines[$i] =~ /bash -lc '$/;
        if ( defined $start && $i > $start && $lines[$i] =~ /^'\s*>"\$output"/ ) {
            $end = $i;
            last;
        }
    }
    die "could not find the embedded bash -lc script in $gate_run_path" if !defined $start || !defined $end;
    my $text = join '', @lines[ $start + 1 .. $end - 1 ];

    # gate-run's own host shell breaks out of the single-quoted block once,
    # '"$SUITE_TIMEOUT"', to substitute ONE value before the text ever
    # reaches the container - a trick that only means what it means nested
    # inside that outer quoting. Extracted and run on its own, the identical
    # three characters are just a single-quoted literal, so the same
    # substitution is made by hand here, matching what gate-run's own host
    # shell would already have done by the time a container ever saw this.
    $text =~ s/'"\$SUITE_TIMEOUT"'/5/g;
    return $text;
}

my $script_text = extract_embedded_script( File::Spec->catfile( $root, 'tools', 'gate-run' ) );
like( $script_text, qr/prove -j"\$JOBS" -lr t/, 'the embedded script was found and looks like the one under test' )
  or BAIL_OUT('extraction failed - nothing else in this file is testing anything real');

# --- build a scratch checkout the extracted script can run against ---------
#
# The extracted text's own FIRST line is `cd /workspace/skills/tira && ...` -
# right where the real gate-run mounts a worktree inside its own container.
# This suite runs inside that same real mount (docker-compose.testing.yml
# binds ./skills to it), so left unmodified this script would `cd` into the
# actual live project and run its stubbed prove/cover/cpanm from there rather
# than from the scratch fixture below - harmless only because the stubs
# intercept every command that could do real damage (prove/cover/cpanm are
# resolved from a PATH-prepended scratch bin, never the real ones), but wrong
# in exactly the way a fixture that leaks into the real tree is always wrong.
# Retargeted to the scratch checkout instead - not a paraphrase of the logic
# under test, only where its very first line is told to land.

my $tmp  = tempdir( CLEANUP => 1 );
my $repo = File::Spec->catdir( $tmp, 'repo' );
mkdir $repo or die $!;
mkdir File::Spec->catdir( $repo, 't' )   or die $!;
mkdir File::Spec->catdir( $repo, 'lib' ) or die $!;
open my $mod, '>', File::Spec->catfile( $repo, 'lib', 'Fake.pm' ) or die $!;
print {$mod} "package Fake; 1;\n";
close $mod;
open my $testfile, '>', File::Spec->catfile( $repo, 't', '01-fake.t' ) or die $!;
print {$testfile} "use Test::More; ok(1); done_testing;\n";
close $testfile;

require File::Copy;
mkdir File::Spec->catdir( $repo, 'tools' ) or die $!;
for my $tool (qw(gate-summarize coverage-complete coverage-guard coverage-holes)) {
    File::Copy::copy( File::Spec->catfile( $root, 'tools', $tool ), File::Spec->catdir( $repo, 'tools' ) )
      or die "copy $tool: $!";
    chmod 0755, File::Spec->catfile( $repo, 'tools', $tool );
}

( my $retargeted_text = $script_text ) =~ s{\Qcd /workspace/skills/tira\E}{cd $repo};
is( ( () = $script_text =~ m{cd /workspace/skills/tira}g ), 1,
    'exactly one real-tree cd to retarget - not zero (the extraction broke) and not more (a second one would go unretargeted)' );

my $script_path = File::Spec->catfile( $tmp, 'embedded.sh' );
open my $sfh, '>', $script_path or die $!;
print {$sfh} "set -euo pipefail\n", $retargeted_text;
close $sfh;

sub write_stub {
    my ( $bindir, $name, $body ) = @_;
    my $path = File::Spec->catfile( $bindir, $name );
    open my $fh, '>', $path or die $!;
    print {$fh} "#!/usr/bin/env bash\n", $body;
    close $fh;
    chmod 0755, $path;
    return;
}

sub run_scenario {
    my (%opt) = @_;
    my $bin = File::Spec->catdir( $tmp, "bin-$opt{name}" );
    mkdir $bin or die $!;

    write_stub( $bin, 'cpanm', "exit 0\n" );
    write_stub( $bin, 'nproc', "echo 2\n" );

    # A stub prove that tells the two calls this script makes apart by
    # whether HARNESS_PERL_SWITCHES names Devel::Cover - exactly the
    # distinction the fix's whole claim rests on - and records each call it
    # sees, in order, to a log the test reads back.
    my $prove_log = File::Spec->catfile( $tmp, "prove-calls-$opt{name}" );
    # A real Devel::Cover run writes one entry per test process into
    # cover_db/runs, which tools/coverage-complete (further down the real
    # script, unchanged) counts against the number of *.t files found - the
    # coverage branch below creates one, so that unchanged check still has
    # something real to pass rather than refusing this fixture for a gap
    # the stub itself would have caused.
    write_stub(
        $bin, 'prove', <<"PROVE"
if [ -n "\${HARNESS_PERL_SWITCHES:-}" ]; then
  echo "coverage" >> "$prove_log"
  mkdir -p cover_db/runs
  touch cover_db/runs/fake.1
  exit $opt{coverage_exit}
else
  echo "plain" >> "$prove_log"
  exit $opt{plain_exit}
fi
PROVE
    );

    # A stub cover/coverage tool chain: coverage-guard already exists for
    # real in tools/, copied in above, but it shells to a real `cover`
    # binary this scratch tree does not have - stubbed to report full marks
    # so the pass-through path (when reached) does not itself refuse.
    write_stub( $bin, 'cover', "echo 'lib/Fake.pm  100.0  100.0  100.0'\nexit 0\n" );

    local $ENV{PATH} = "$bin:$ENV{PATH}";
    local $ENV{HARNESS_PERL_SWITCHES} = $opt{inherited_switches} if defined $opt{inherited_switches};
    my $out = `cd $repo && bash $script_path 2>&1`;
    my $status = $? >> 8;

    my @calls;
    if ( open my $lfh, '<', $prove_log ) {
        @calls = <$lfh>;
        close $lfh;
        chomp @calls;
    }
    return { out => $out, status => $status, calls => \@calls };
}

# --- a plain failure refuses before coverage is ever touched ---------------

my $red = run_scenario( name => 'plain-fails', plain_exit => 1, coverage_exit => 0 );
is_deeply( $red->{calls}, ['plain'], 'a failing plain pass is the only prove call made - coverage never starts' );
isnt( $red->{status}, 0, 'and the embedded script itself exits non-zero' );

# --- a green plain pass falls through into the existing coverage pass ------

my $green = run_scenario( name => 'plain-passes', plain_exit => 0, coverage_exit => 0 );
is_deeply( $green->{calls}, [ 'plain', 'coverage' ], 'a passing plain pass is followed by exactly one coverage pass, unchanged' );
is( $green->{status}, 0, 'and the whole script succeeds' );

# --- passing plain but failing coverage still fails the gate ---------------

my $mixed = run_scenario( name => 'coverage-fails', plain_exit => 0, coverage_exit => 1 );
ok( grep( { $_ eq 'coverage' } @{ $mixed->{calls} } ) >= 1, 'a passing plain pass still reaches the coverage pass' );
isnt( $mixed->{status}, 0, 'and a coverage failure after a plain pass still fails the gate - the plain pass is a filter, never a substitute' );

# --- the plain pass is genuinely plain even if the environment already carries HARNESS_PERL_SWITCHES -----
#
# Codex-caught: a plain pass that only omits SETTING the variable is not
# plain if the container's own environment already exports it - the
# supposedly-plain prove call would still be instrumented, silently paying
# the cost this whole card exists to avoid on every single run.

my $inherited = run_scenario(
    name => 'inherited-switches', plain_exit => 0, coverage_exit => 0,
    inherited_switches => '-MDevel::Cover',
);
is( $inherited->{calls}[0], 'plain',
    'the plain pass logs itself as plain even with HARNESS_PERL_SWITCHES already exported by the environment - it is explicitly unset, not merely left unassigned' );

done_testing();

__END__

=head1 NAME

t/969-a-coverage-run-paid-for-a-plain-failure.t - a plain suite failure must
refuse before any coverage run starts

=head1 DESCRIPTION

TKT-969: an identical suite costs roughly nine times as much under
Devel::Cover as it does plain (86s vs 788-801s, measured 2026-09-06), and
three of six gate attempts that day failed on a plain suite failure while
still paying the full instrumented cost to learn it.

tools/gate-run's embedded container script now runs the suite plain first,
with no C<HARNESS_PERL_SWITCHES>. A plain failure is reported through the
same C<tools/gate-summarize> a coverage failure already uses (so the failing
file is named, not only a test number) and refuses immediately - the
existing coverage pass, its retry-on-collision loop, and the 100% check are
never reached. A plain pass falls through into that existing logic entirely
unchanged, so a tree that passes plain and fails under coverage still fails
the gate - the plain pass is a fail-fast filter, never a certifying
substitute for it.

Tested by extracting the literal script text C<tools/gate-run> hands to
C<bash -lc> and running it against a scratch checkout with stub
C<prove>/C<cpanm>/C<nproc>/C<cover> - the real logic under test, distinguished
by whether C<HARNESS_PERL_SWITCHES> names C<Devel::Cover>, which is exactly
the fact the fix's whole claim rests on.

=cut
