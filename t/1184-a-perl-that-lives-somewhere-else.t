#!/usr/bin/env perl
# TKT-1184. _resolve_bare_command (TKT-1129) resolves a scheduled job's bare
# command word beside $^X before falling back to $ENV{PATH}, on the
# documented assumption that "a d2/local::lib install always puts its own
# wrapper scripts in the same bin/ as $^X". That assumption is false for d2
# itself: its own shebang is `#!/usr/bin/env perl`, which resolves $^X to
# whichever perl is first on PATH at exec time (the system perl) rather than
# the local::lib perl d2 is installed beside - so the beside-perl check never
# matches for d2, tira's own most common job command.
#
# Reproduced here without $^X (this test cannot make Perl's own $^X point
# somewhere it does not): a scratch bin/ directory holds an executable, the
# real $^X's own directory does NOT hold one of that name, and only
# PERL_LOCAL_LIB_ROOT names the scratch root. If resolution finds it, the
# new check works; the beside-perl and PATH checks alone would return the
# bare word unchanged, since neither can see it.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
require Tira::CLI::Police::Jobs;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'localperl' );
my $bin  = File::Spec->catdir( $root, 'bin' );
mkdir $root or die $!;
mkdir $bin  or die $!;

my $word = 'a-tool-only-perl-local-lib-root-finds-1184';
my $tool = File::Spec->catfile( $bin, $word );
open my $fh, '>', $tool or die $!;
close $fh;
chmod 0755, $tool;

# --- resolved via PERL_LOCAL_LIB_ROOT, not via $^X or $ENV{PATH} -----------

{
    local $ENV{PERL_LOCAL_LIB_ROOT} = $root;
    local $ENV{PATH} = '/nonexistent-1184-a';
    my $resolved = Tira::CLI::Police::Jobs::_resolve_bare_command($word);
    is( $resolved, $tool,
        'a word only PERL_LOCAL_LIB_ROOT/bin names is resolved there' );
}

# --- PERL_LOCAL_LIB_ROOT unset falls through exactly as before -------------

{
    local $ENV{PERL_LOCAL_LIB_ROOT};
    delete $ENV{PERL_LOCAL_LIB_ROOT};
    local $ENV{PATH} = '/nonexistent-1184-b';
    my $resolved = Tira::CLI::Police::Jobs::_resolve_bare_command($word);
    isnt( $resolved, $tool,
        'with no PERL_LOCAL_LIB_ROOT and no PATH match, the word is not found there' );
}

# --- a relative PERL_LOCAL_LIB_ROOT is never trusted, the same standard
# every other candidate here is held to (Codex review precedent, TKT-1129)

{
    local $ENV{PERL_LOCAL_LIB_ROOT} = 'localperl';    # relative, not absolute
    local $ENV{PATH} = '/nonexistent-1184-c';
    my $resolved = Tira::CLI::Police::Jobs::_resolve_bare_command($word);
    isnt( $resolved, $tool,
        'a relative PERL_LOCAL_LIB_ROOT is skipped, not trusted' );
}

# --- a STACKED PERL_LOCAL_LIB_ROOT (colon-separated, active root
# prepended, per local::lib's own docs) checks each root, not just the
# first (Codex review) ---------------------------------------------------

{
    local $ENV{PERL_LOCAL_LIB_ROOT} = "/nonexistent-1184-stacked:$root";
    local $ENV{PATH} = '/nonexistent-1184-d';
    my $resolved = Tira::CLI::Police::Jobs::_resolve_bare_command($word);
    is( $resolved, $tool,
        'a word found under the SECOND stacked root is still resolved, not just the first' );
}

# --- a PATH match still works when PERL_LOCAL_LIB_ROOT does not name it ----

{
    local $ENV{PERL_LOCAL_LIB_ROOT} = '/nonexistent-root-1184';
    local $ENV{PATH} = $bin;
    my $resolved = Tira::CLI::Police::Jobs::_resolve_bare_command($word);
    is( $resolved, $tool,
        'a word PERL_LOCAL_LIB_ROOT does not name is still found via PATH' );
}

done_testing;

__END__

=head1 NAME

1184-a-perl-that-lives-somewhere-else.t - _resolve_bare_command also checks
PERL_LOCAL_LIB_ROOT/bin, since $^X's own directory is not always where a
local::lib install's own wrapper scripts live

=head1 DESCRIPTION

TKT-1184. d2's own shebang (C<#!/usr/bin/env perl>) resolves C<$^X> to the
system perl at exec time, not the local::lib perl d2 is installed beside, so
C<_resolve_bare_command>'s beside-C<$^X> check (TKT-1129) never matches for
d2 itself - the exact command tira's own JOB-004 schedules every 30 minutes.
C<PERL_LOCAL_LIB_ROOT>, set by local::lib's own activation independent of
both C<$^X> and C<$ENV{PATH}>, reliably names the root whose C<bin/> holds
exactly these wrapper scripts, and is checked first, before the beside-C<$^X>
and C<$ENV{PATH}> fallbacks - purely additive, never removing either existing
check's own coverage.

=cut
