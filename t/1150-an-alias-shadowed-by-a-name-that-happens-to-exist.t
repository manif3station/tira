#!/usr/bin/env perl
# TKT-1009. discover_project() only consults its path_resolver (the alias
# lookup) when '!-e $candidate' - so if a literal file or directory happens
# to exist at a path matching the alias name relative to cwd, alias
# resolution is skipped entirely: the literal (wrong, unrelated) path is
# walked up instead, and "No Tira project found from ALIAS" is raised even
# though the alias itself resolves to a real project. Reproduced live: a
# stray ./tira-ddd/.tira/ directory, written by an unrelated bug, broke
# every subsequent d2 tira.* command run from that checkout, because
# discover_project saw the literal ./tira-ddd existed and never tried the
# alias resolver at all.
#
# WRITTEN RED.

use strict;
use warnings;

use Cwd ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'real-project' );

my $tira = Tira->new(
    clock         => sub {'2026-09-22T00:00:00Z'},
    path_resolver => sub { return $_[0] eq 'foo' ? $root : undef },
);
$tira->project_new(
    name => 'Real', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
);

# A literal directory named exactly like the alias, coincidentally present
# relative to cwd, and unrelated to any Tira project (no .tira/ anywhere up
# its own chain within this isolated tmp tree).
my $cwd = File::Spec->catdir( $tmp, 'cwd' );
mkdir $cwd or die $!;
mkdir File::Spec->catdir( $cwd, 'foo' ) or die $!;

my $real_cwd = Cwd::getcwd();
chdir $cwd or die $!;
my $resolved = eval { $tira->discover_project( project => 'foo' ) };
my $error = $@;
chdir $real_cwd or die $!;

is( $error, '', 'resolving the alias does not die just because a same-named literal directory exists' )
  or diag("discover_project died: $error");
is( $resolved, $root,
    'and it resolves to the ALIASED project, not the coincidental literal directory' );

# --- two aliases naming each other must not recurse forever -----------------
#
# The fallback is tried AT MOST ONCE per call, never re-entered on its own
# result - otherwise 'foo' -> 'bar', 'bar' -> 'foo', both existing and
# neither a project, would alternate forever (Codex review).

{
    my $cwd2 = File::Spec->catdir( $tmp, 'cwd2' );
    mkdir $cwd2 or die $!;
    mkdir File::Spec->catdir( $cwd2, 'alpha' ) or die $!;
    mkdir File::Spec->catdir( $cwd2, 'beta' )  or die $!;

    my $cyclic = Tira->new(
        clock         => sub {'2026-09-22T00:00:00Z'},
        path_resolver => sub {
            return File::Spec->catdir( $cwd2, 'beta' )  if $_[0] eq File::Spec->catdir( $cwd2, 'alpha' );
            return File::Spec->catdir( $cwd2, 'alpha' ) if $_[0] eq File::Spec->catdir( $cwd2, 'beta' );
            return undef;
        },
    );

    chdir $cwd2 or die $!;
    my $cyclic_resolved = eval { $cyclic->discover_project( project => 'alpha' ) };
    my $cyclic_error = $@;
    chdir $real_cwd or die $!;

    ok( !$cyclic_resolved, 'two aliases naming each other do not resolve to a project - there is none' );
    like( $cyclic_error, qr/No Tira project found/,
        'and the call returns (rather than recursing forever) with the ordinary refusal' );
}

# --- a resolved alias target that also fails must never be named ------------
#
# The existing non-disclosure promise (an alias's resolved path never
# appears in Tira output or errors) has to hold for this new fallback path
# too, not only for the original alias branch (Codex review).

{
    my $cwd3 = File::Spec->catdir( $tmp, 'cwd3' );
    mkdir $cwd3 or die $!;
    mkdir File::Spec->catdir( $cwd3, 'gamma' ) or die $!;
    my $secret_target = File::Spec->catdir( $tmp, 'secret-customer-board' );
    mkdir $secret_target or die $!;

    my $leaky = Tira->new(
        clock         => sub {'2026-09-22T00:00:00Z'},
        path_resolver => sub { return $_[0] eq 'gamma' ? $secret_target : undef },
    );

    chdir $cwd3 or die $!;
    my $leaky_resolved = eval { $leaky->discover_project( project => 'gamma' ) };
    my $leaky_error = $@;
    chdir $real_cwd or die $!;

    ok( !$leaky_resolved, 'a resolved target that is also not a project still refuses' );
    like( $leaky_error, qr/'gamma'/, 'and the refusal names the SELECTOR' );
    unlike( $leaky_error, qr/secret-customer-board/,
        'never the resolved target - the same non-disclosure the alias branch already promises' );
}

done_testing;

__END__

=head1 NAME

1150-an-alias-shadowed-by-a-name-that-happens-to-exist.t - a coincidental
literal path must not shadow a registered alias

=head1 DESCRIPTION

TKT-1009. C<discover_project()>'s existence check ('!-e $candidate') skips
the alias resolver entirely whenever a literal file or directory happens to
exist at a path matching the alias name, relative to cwd - even though that
literal path has nothing to do with the alias and walking up from it finds
no C<.tira/project.yml>. The fix is to fall back to the alias resolver in
that case, before raising "No Tira project found".

=cut
