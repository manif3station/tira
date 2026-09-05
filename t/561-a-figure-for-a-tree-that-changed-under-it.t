#!/usr/bin/env perl
# TKT-605. Hit live: a coverage run measured lib/Tira/CLI.pm while another
# card's own work edited it concurrently, and reported "1203 UNCOVERED" -
# every one of those statements was actually covered. The only reason the
# figure was not simply believed is that 1203 was too absurd to trust; a
# quieter interference producing "3 uncovered" would have sent somebody
# hunting a phantom line, which is precisely the hunt a coverage figure
# exists to save.
#
# tools/gate-cache-read already states the standard this reuses: "not a
# claim, a record that could only have been produced by actually having
# that tree." That tool keys on the committed tree (git rev-parse
# HEAD^{tree}), which cannot see this failure at all - the whole bug is an
# UNCOMMITTED edit landing mid-run. tools/coverage-guard fingerprints lib/'s
# actual bytes on disk instead, before and after the wrapped command, and
# refuses to trust anything it reported if they differ.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $root = File::Spec->rel2abs('.');
my $guard = File::Spec->catfile( $root, 'tools', 'coverage-guard' );
ok( -x $guard, 'tools/coverage-guard exists and is executable' );

# A scratch project with its own lib/, so this never touches the real one.
my $tmp = tempdir( CLEANUP => 1 );
mkdir File::Spec->catdir( $tmp, 'tools' );
mkdir File::Spec->catdir( $tmp, 'lib' );

{
    open my $fh, '<', $guard or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    my $copy = File::Spec->catfile( $tmp, 'tools', 'coverage-guard' );
    open my $out, '>', $copy or die $!;
    print {$out} $body;
    close $out;
    chmod 0755, $copy;
}

my $module = File::Spec->catfile( $tmp, 'lib', 'Foo.pm' );
open my $fh, '>', $module or die $!;
print {$fh} "package Foo;\n1;\n";
close $fh;

sub run_guard {
    my (@cmd) = @_;
    my $was = File::Spec->rel2abs('.');
    chdir $tmp or die "cannot enter $tmp: $!";
    my $quoted = join ' ', map { my $a = $_; $a =~ s/'/'\\''/g; "'$a'" } @cmd;
    my $out = `tools/coverage-guard -- $quoted 2>&1`;
    my $status = $? >> 8;
    chdir $was or die "cannot return to $was: $!";
    return ( $out, $status );
}

# --- an unchanged tree reports exactly as before ---------------------------

my ( $clean_out, $clean_status ) = run_guard( 'echo', 'coverage: 100%' );
is( $clean_status, 0, 'the wrapped command exit status passes through when lib/ did not change' );
like( $clean_out, qr/coverage: 100%/, "and the wrapped command's own output is not swallowed" );
unlike( $clean_out, qr/coverage-guard: lib\/ changed/,
    'no refusal is printed when nothing under lib/ changed' );

# --- a file edited while the command runs is refused, and named ------------

my $interferer = File::Spec->catfile( $tmp, 'interfere.pl' );
open my $ifh, '>', $interferer or die $!;
print {$ifh} sprintf( <<'PERL', $module );
open my $fh, '>', '%s' or die $!;
print {$fh} "package Foo;\n2;\n";
close $fh;
print "coverage: 3 uncovered\n";
PERL
close $ifh;

my ( $interfered_out, $interfered_status ) = run_guard( 'perl', $interferer );
isnt( $interfered_status, 0, 'a run that interfered with lib/ is refused, not exit 0' );
like( $interfered_out, qr/coverage-guard: lib\/ changed while the command ran/,
    "the refusal says why - a wrong number offered as though it were real is worse than none" );
like( $interfered_out, qr/Foo\.pm/, 'and the refusal names the file that changed' );

# --- the command's own failure is not hidden behind a false "lib/ changed" --

my ( $failed_out, $failed_status ) = run_guard( 'perl', '-e', 'print "job failed on its own\n"; exit 7' );
is( $failed_status, 7, "the wrapped command's own exit code survives when lib/ did not change" );
like( $failed_out, qr/job failed on its own/, 'the wrapped command is there to be read' );
unlike( $failed_out, qr/coverage-guard: lib\/ changed/,
    'and that failure is not misreported as tree interference' );

done_testing();

__END__

=head1 NAME

561-a-figure-for-a-tree-that-changed-under-it.t - a coverage run no longer reports a number for a tree that changed under it

=head1 DESCRIPTION

TKT-605. C<tools/coverage-guard> fingerprints every C<lib/*.pm> file's bytes
before and after the command it wraps, and refuses - naming which file
changed - rather than let a coverage run's own figure be believed when the
tree it measured stopped existing partway through. An unchanged tree still
reports exactly as before, including the wrapped command's own exit status
and output.

=cut
