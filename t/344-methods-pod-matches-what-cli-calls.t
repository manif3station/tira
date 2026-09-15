#!/usr/bin/env perl
# lib/Tira.pm's own POD METHODS section documented exactly 5 engine methods -
# new, create_project, discover_project, create_record, format_output - the
# same 5 since the project's earliest version, while the engine grew to 100+
# public methods. Nothing ever compared the section against what the engine
# actually exposes, so it went stale silently and stayed that way.
#
# Found live: a required-action item's proof read "grep for a =head2 entry,
# find none, mark done citing project convention" - treating an unmaintained,
# incomplete section as a legitimate convention to hand-wave past. TKT-478.
#
# The scope this test holds the section to is exactly what Tira::CLI actually
# calls on $tira - the real external API surface - not every sub in the
# module, most of which are private implementation detail already marked
# with a leading underscore and rightly excluded.

use strict;
use warnings;

use File::Find qw(find);
use Test::More;

# READS THE ENGINE'S POD ON PURPOSE - t/486 marker: about this file, not its
# code. Tira.pm's own POD is deliberately where the lifted modules' methods
# stay documented (TKT-832) - so the section this compares really is this
# file's own. Since TKT-1098 that POD lives in a sibling lib/Tira.pod (the
# standard CPAN same-basename convention), not inline in lib/Tira.pm any
# more - read from there instead. The CALLERS are already found by walking
# lib/Tira below, which is the half that had to follow the code.
my $module = 'lib/Tira.pod';
open my $fh, '<', $module or die "Cannot read $module: $!";
my $pod = do { local $/; <$fh> };
close $fh;

my %documented;
$documented{$1}++ while $pod =~ /^=head2\s+(\S+)/mg;

my @cli_files;
find( { no_chdir => 1, wanted => sub {
    push @cli_files, $File::Find::name if -f && /\.pm\z/;
} }, 'lib/Tira' );
push @cli_files, 'lib/Tira/CLI.pm';

my %called;
for my $file (@cli_files) {
    open my $cli_fh, '<', $file or die "Cannot read $file: $!";
    my $text = do { local $/; <$cli_fh> };
    close $cli_fh;
    $called{$1}++ while $text =~ /\$tira->([a-zA-Z_][a-zA-Z0-9_]*)/g;

    # And the ones reached through the string dispatch table, which the
    # pattern above cannot see. Entries read 'release.record' =>
    # 'release_record', and the method is then called on $tira through a
    # variable, so no literal $tira->release_record( ever appears. Those
    # methods are as public as any other - a command name maps straight onto
    # one - but for as long as this guard only read call sites, every one of
    # them sat outside the scope it believed it was enforcing. When TKT-568
    # widened it, 22 undocumented methods appeared at once, which is a fifth
    # of the documented surface and precisely the drift this file exists to
    # stop. Matching the value of a 'command.name' => 'method_name' pair is
    # narrow enough not to catch ordinary option or field mappings, whose
    # keys are bare words rather than dotted command names.
    $called{$1}++
      while $text =~ /'[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+'\s*=>\s*'([a-z][a-z0-9_]*)'/g;
}

# Private helpers a caller could in principle reach through $tira-> are not
# part of the documented API - the leading underscore is the project's own
# marker for "implementation detail," honoured here rather than re-decided.
my @undocumented = sort grep { !/^_/ && !$documented{$_} } keys %called;

is_deeply( \@undocumented, [],
    'every method Tira::CLI calls on $tira has a =head2 entry in the METHODS POD' );

# TKT-670. A method documented ONCE satisfies the test above just as well as
# one documented twice - so a stale duplicate (column_update had two
# =head2 entries, one filed with record_update describing an unrelated
# refusal it no longer carries, TKT-591's own POD split having left the old
# one behind) went unnoticed by this file for the same reason a missing
# entry used to: nothing counted, only presence/absence was ever asked.
my @duplicated = sort grep { $documented{$_} > 1 } keys %documented;
is_deeply( \@duplicated, [],
    'no method has more than one =head2 entry in the METHODS POD' )
  or diag( "documented more than once: " . join( ', ', @duplicated ) );

done_testing;

__END__

=head1 NAME

344-methods-pod-matches-what-cli-calls.t - the METHODS section cannot go stale unnoticed again

=head1 DESCRIPTION

Compares lib/Tira.pm's own C<=head2> entries against every method
C<Tira::CLI> actually calls on C<$tira>, so a public method added without a
POD entry - the exact failure TKT-478 found five methods and a decade of
silence after the section was first written - fails a gate instead of
passing one.

=cut
