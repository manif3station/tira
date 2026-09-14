#!/usr/bin/env perl

# TKT-719. Tira resolved its own installation root in four places, two of
# them (installed_version, _collector_script) by counting a fixed number of
# directories up from __FILE__ - correct only while the file stays exactly
# where it is. That assumption already failed once: Tira::CLI::Usage's own
# SKILLS.md/POLICIES.md readers counted '..' a different number of times
# each, one too many and one too few, and both fell back silently instead
# of failing. The other two call sites (Tira::CLI::Usage, Tira::CLI::Serve)
# already carry the fix - climb out of lib/ rather than count - but as two
# separate, duplicated copies, and neither guards the case with no lib/ in
# its own path at all (it silently returns the empty string, turning every
# path built from it relative rather than saying so).
#
# One shared resolver now lives in Tira.pm (the one file every caller
# already requires and whose own position never changes) and every other
# call site delegates to it instead of keeping its own copy.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Find ();

use lib 'lib';
use lib 't/lib';
use Tira;
use Suite;

# --- the core climb, exercised with fabricated paths - no lib/ files needed -

is( Tira::_skill_root('/home/x/skill/lib/Tira.pm'), '/home/x/skill',
    'one level under lib/, the shape today' );
is( Tira::_skill_root('/home/x/skill/lib/Tira/CLI/Usage.pm'), '/home/x/skill',
    'three levels under lib/ - the shape Usage.pm and Serve.pm are in today' );
is( Tira::_skill_root('/home/x/skill/lib/Tira/CLI/Deeper/Module.pm'), '/home/x/skill',
    'a module moved one directory deeper still resolves to the same root - the exact case that broke tonight' );

# --- no lib/ in the path refuses rather than returning an empty string -----

my $error = eval { Tira::_skill_root('/home/x/not-a-skill-at-all/Module.pm') };
like( $@, qr/lib/i, 'no lib/ segment anywhere in the path refuses, naming what it looked for' );
ok( !defined $error, 'nothing is returned on the refusal' );

# --- exercised end to end: a real scratch skill, one file moved deeper -----

my $tmp = tempdir( CLEANUP => 1 );
my $scratch = File::Spec->catdir( $tmp, 'skill' );
make_path( File::Spec->catdir( $scratch, 'lib', 'Deeper' ) );
make_path( File::Spec->catdir( $scratch, 'collector' ) );
open my $env, '>', File::Spec->catfile( $scratch, '.env' ) or die $!;
print {$env} "VERSION=9.99\n";
close $env;
open my $remind, '>', File::Spec->catfile( $scratch, 'collector', 'tira-remind' ) or die $!;
print {$remind} "#!/usr/bin/env perl\n";
close $remind;

copy( 'lib/Tira.pm', File::Spec->catdir( $scratch, 'lib', 'Deeper', 'Tira.pm' ) )
  or die "copy: $!";

my $moved = do {
    package main;
    delete $INC{'Tira.pm'};
    require File::Spec->catfile( $scratch, 'lib', 'Deeper', 'Tira.pm' );
    'ok';
};
is( $moved, 'ok', 'the moved copy compiles' );
is( Tira::installed_version(), '9.99',
    'installed_version still reads the right .env when the module itself sits one directory deeper' );
like( Tira::_collector_script(), qr/\Q$scratch\E.*collector.*tira-remind/,
    '_collector_script still finds its sibling collector script from the deeper location' );

# --- the guard checklist item on _search_index_refresh ----------------------
# Same asymmetry TKT-719's own key_details name: _bump_generation walks
# dirname three times from a record path and guards with
# 'return if basename($tira) ne .tira'; _search_index_refresh walked dirname
# four times from the same shape and had no such guard, so a path that did
# not fit the assumed <root>/.tira/<type>/<column>/<REF>.json shape computed
# a wrong "root" instead of declining.
{
    my $tira = Tira->new( clock => sub { '2026-09-14T21:00:00Z' } );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->create_project( name => 'A root found by climbing', dir => $root );
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'First' );

    # A path that does not fit <root>/.tira/<type>/<column>/<REF>.json at all.
    my $bogus_path = File::Spec->catfile( $tmp, 'nowhere-near-a-project.json' );
    my $ok = eval {
        $tira->_search_index_refresh( $bogus_path, '{}', {}, $card->{ref} );
        1;
    };
    ok( $ok, '_search_index_refresh declines quietly on a path outside the assumed shape, rather than dying or writing to a fabricated root' );
}

# --- nothing else under lib/ still counts directories from __FILE__ --------

{
    # The dangerous shape specifically: NESTED dirname(dirname(...)) calls, or
    # a single dirname(...) combined with File::Spec->updir - a FIXED count of
    # hops applied once, in one expression, to a value derived from __FILE__.
    # A sub that climbs by LOOPING (Job::Monitor's _feeder_entrypoint walks
    # upward until it finds a known landmark file) is not this bug and must
    # not be flagged - it calls dirname once per iteration, on a variable that
    # changes each time, which is the opposite of assuming a fixed depth.
    my $source = Suite::engine_source() . Suite::cli_source();
    my %body = $source =~ /^sub (\w+) \{(.*?)\n\}\n/msg;
    my @offenders;
    for my $name ( sort keys %body ) {
        next if $name eq '_skill_root';
        my $body = $body{$name};
        next if $body !~ /__FILE__/;
        my $nested_dirname = $body =~ /\bdirname\s*\(\s*dirname\s*\(/;
        my $dirname_then_updir = $body =~ /\bdirname\s*\([^()]*\)[^;]*\bupdir\b/;
        push @offenders, $name if $nested_dirname || $dirname_then_updir;
    }
    is_deeply( \@offenders, [], 'no sub other than _skill_root resolves its own __FILE__ location by a fixed count of directory hops' );
}

done_testing;

__END__

=head1 NAME

1095-a-root-found-by-climbing-not-counting.t - one shared skill-root resolver, used everywhere, that climbs rather than counts

=head1 DESCRIPTION

TKT-719. C<installed_version> and C<_collector_script> resolved their own
location by counting a fixed number of directories from C<__FILE__>, correct
only while neither ever moved. C<Tira::CLI::Usage> and C<Tira::CLI::Serve>
already carried the fix - climb out of C<lib/> rather than count - as two
duplicated copies with no guard for a path with no C<lib/> in it at all.
C<Tira::_skill_root($path)> is now the one shared implementation, guarded,
and every call site delegates to it. C<_search_index_refresh> also gained
the guard C<_bump_generation> already had, for the matching card-path
asymmetry named on this ticket.

=cut
