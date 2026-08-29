#!/usr/bin/env perl
# Every module under lib/ has to be able to answer for itself.
#
# TKT-607 split a 6,048-line Tira::CLI into eight modules, and three separate
# times the split produced code that compiled and did not run:
#
#   1. Tira::CLI kept calling _usage() after _usage moved to Tira::CLI::Usage.
#      perl -c was happy - a bare _name() is a legal call to a sub that might be
#      defined later - and every command that touches the help or error path
#      died at runtime. It surfaced as 190 test files failing with no output at
#      all, because they capture STDOUT and STDERR into scalars.
#
#   2. Tira::CLI::Police called Tira::CLI::Serve::_process_command with nothing
#      loading Serve. Same shape: compiles, dies when reached.
#
#   3. Tira::CLI::Usage used dirname(), which Tira::CLI imports from
#      File::Basename and Usage did not. Same shape again.
#
# All three are the same mistake - a rename is only half a move, and the other
# half is that the name has to resolve where it now sits - and none of them is
# visible to `perl -c`. That is the gap this file fills: it resolves, for every
# module under lib/, every function it calls, and requires an answer.
#
# IT WALKS lib/ RATHER THAN NAMING THE MODULES. There are eight today and there
# will be more; a list here would be maintained by exactly the discipline that
# let all three of these through. Same reasoning as t/429 for the coverage gate
# and t/144 for the bridge writers.

use strict;
use warnings;

use File::Find ();
use Test::More;

my @modules;
File::Find::find(
    { no_chdir => 1, wanted => sub { push @modules, $File::Find::name if /\.pm\z/ } },
    'lib' );
@modules = sort @modules;

cmp_ok( scalar @modules, '>=', 8,
    'lib/ was walked - ' . join( ', ', @modules ) );

# --- what each module defines, and what every module can see -----------------

my ( %source, %defines );
for my $module (@modules) {
    open my $handle, '<', $module or die "$module: $!";
    my $text = do { local $/; <$handle> };
    close $handle;

    # POD and comments mention subs constantly - "_item_is_done", "calls
    # _police_store" - and none of that is a call. Reading them as calls would
    # make this file fail on prose, which is the fault t/429's second version
    # had in the other direction: it passed because a COMMENT named a module.
    $text =~ s/^=\w.*?^=cut//gsm;
    $text =~ s/^\s*#.*$//gm;

    $source{$module}  = $text;
    $defines{$module} = { map { $_ => 1 } $text =~ /^sub (\w+)/gm };
}

my %package_of = map {
    my ($package) = $source{$_} =~ /^package ([\w:]+);/m;
    ( $_ => $package // '' )
} @modules;

# --- every unqualified call resolves in the file that makes it ----------------
#
# One assertion per module rather than a count, so a failure names the module
# and the sub instead of reporting that some number is wrong.

# A CODE REFERENCE IS NOT A CALL, and looking only for calls is how
# \&_serve_browser survived the move untouched: Tira::CLI took it as a default
# on every run, it named a sub that had gone to Tira::CLI::Serve, and it died in
# whichever command first tried to serve a board. The reference form is matched
# here alongside the call form for exactly that reason.

for my $module (@modules) {
    my %called = map { $_ => 1 } (
        $source{$module} =~ /(?<![\w:>\$])(_[a-z][a-z0-9_]*)\s*\(/g,
        $source{$module} =~ /\\&(_[a-z][a-z0-9_]*)\b/g,
    );
    my @dangling = sort grep { !$defines{$module}{$_} } keys %called;
    is_deeply( \@dangling, [],
        "$module calls only helpers it defines - dangling: "
          . ( join( ', ', @dangling ) || 'none' ) );
}

# --- every qualified call names a package that something loads ----------------
#
# The Police-calls-Serve fault. A fully qualified call is not a compile error
# and not a link error; it is a runtime death in whichever command reaches it
# first, which may be one nobody runs in development.

my %provides = map { $package_of{$_} => $_ } grep { $package_of{$_} } @modules;

for my $module (@modules) {
    # Every sub per package, not one. The first version wrote
    # $wanted{$package} = $sub, so a module calling six things in Tira::CLI::Serve
    # was checked for whichever the regex matched last, and a failure reported
    # "missing: Tira::CLI::Serve" without naming what was missing from it.
    my %wanted;
    # `use Tira::CLI::Serve ();` reads as a call to Tira::CLI::Serve() with the
    # empty list - same shape, opposite meaning - so the import forms are
    # excluded by name. Without that, every module that correctly declares its
    # dependency was reported as calling a sub that does not exist.
    while ( $source{$module}
        =~ /(?<!use )(?<!require )\b(Tira::CLI(?:::\w+)?)::(\w+)\s*\(/g )
    {
        my ( $package, $sub ) = ( $1, $2 );
        next if $package eq $package_of{$module};
        $wanted{$package}{$sub} = 1;
    }
    my @unloaded = sort grep {
        my $package = $_;
        $source{$module} !~ /^\s*(?:use|require) \Q$package\E\b/m
    } keys %wanted;
    is_deeply( \@unloaded, [],
        "$module loads every package it calls into - missing: "
          . ( join( ', ', @unloaded ) || 'none' ) );

    # And every sub it calls has to be there, named individually so a failure
    # says which one.
    my @missing;
    for my $package ( sort keys %wanted ) {
        my $file = $provides{$package} or next;
        push @missing, map {"$package\::$_"}
          sort grep { !$defines{$file}{$_} } keys %{ $wanted{$package} };
    }
    is_deeply( \@missing, [],
        "$module calls subs that exist where it says they are - missing: "
          . ( join( ', ', @missing ) || 'none' ) );
}

# --- and every imported function is imported where it is used -----------------
#
# The dirname fault. Tira::CLI imports a handful of functions by name, and code
# moved out of it kept calling them into a package that never asked for them.

my %imports = (
    decode              => 'Encode',
    encode_utf8         => 'Encode',
    abs_path            => 'Cwd',
    cwd                 => 'Cwd',
    dirname             => 'File::Basename',
    GetOptionsFromArray => 'Getopt::Long',
);

for my $module (@modules) {
    my @unimported;
    for my $function ( sort keys %imports ) {
        next if $source{$module} !~ /(?<![\w:>\$])\Q$function\E\s*\(/;
        next if $defines{$module}{$function};
        my $from = $imports{$function};
        push @unimported, "$function (from $from)"
          if $source{$module} !~ /^use \Q$from\E\b[^\n]*\b\Q$function\E\b/m;
    }
    is_deeply( \@unimported, [],
        "$module imports every function it calls by name - missing: "
          . ( join( ', ', @unimported ) || 'none' ) );
}

done_testing();

__END__

=head1 NAME

t/431-a-module-that-can-stand-on-its-own.t - every module under lib/ must
resolve every name it uses

=head1 DESCRIPTION

C<perl -c> accepts a call to a sub that is not defined: C<_usage()> parses as a
call to something that might arrive later, and a fully qualified
C<Tira::CLI::Serve::_process_command()> parses whether or not anything ever
loads that package. Both die at runtime, in whichever command reaches them
first.

TKT-607 produced all three variants of that while splitting C<Tira::CLI> into
eight modules - an unqualified call to a sub that had moved, a qualified call
into a package nothing loaded, and C<dirname> used in a module that never
imported it. Each compiled. The first surfaced as 190 test files failing with no
output at all, because they capture C<STDOUT> and C<STDERR> into scalars and the
death went into the scalar.

This file resolves every call in every module: unqualified calls against what
that file defines, qualified calls against what the named package defines and
whether the caller loads it, and imported functions against the C<use> lines
that would bring them in.

It walks C<lib/> rather than naming the modules, for the reason C<t/429> walks
it for the coverage gate: a list is maintained by somebody remembering, and the
three faults above are what remembering is worth.

=cut
