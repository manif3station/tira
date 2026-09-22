#!/usr/bin/env perl
# TKT-646. policy_list(%args) took every filter option the CLI parser
# accepts - --rule, --id, --action, --column, --ref, --author, --enter,
# --age - and returned the whole declared list regardless. All eight
# parsed successfully, at exit 0, with no error and no filtering: the
# option looked accepted and did nothing.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-22T00:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new( name => 'Filters', dir => $root, members => ['claude'] );

my $pol1 = $tira->policy_add( project => $root, rule => 'card-duration', column => 'backlog', age => '4h', action => 'bridge-reminder' );
my $pol2 = $tira->policy_add( project => $root, rule => 'unpushed-work', age => '1h', action => 'bridge-reminder' );

is( scalar @{ $tira->policy_list( project => $root ) }, 2, 'unfiltered, both declared policies come back' );

# --- --rule actually filters --------------------------------------------

{
    my $filtered = $tira->policy_list( project => $root, rule => 'card-duration' );
    is( scalar @{$filtered}, 1, '--rule narrows the list to matching policies' )
      or diag( 'got ' . scalar( @{$filtered} ) . ' policies back' );
    is( $filtered->[0]{id}, $pol1->{id}, 'and it is the right one' ) if @{$filtered};
}

# --- --id actually filters ------------------------------------------------

{
    my $filtered = $tira->policy_list( project => $root, id => $pol2->{id} );
    is( scalar @{$filtered}, 1, '--id narrows the list to one policy' )
      or diag( 'got ' . scalar( @{$filtered} ) . ' policies back' );
}

# --- --author is harmlessly ignored, NEVER refused - it is not a caller- --
# --- supplied filter at all, it is the ambient TIRA_AUTHOR write-attribution
# --- key every command's %args carries, present on essentially every real
# --- invocation this project's own convention makes (Codex review: a first
# --- draft died whenever it was set, which would have refused policy.list
# --- under this session's own TIRA_AUTHOR=claude setup) --------------------

{
    my $result = eval { $tira->policy_list( project => $root, author => 'claude' ) };
    is( $@, '', 'policy_list does not die just because %args carries an author key' )
      or diag("died: $@");
    is( scalar @{ $result // [] }, 2, 'and author is not treated as a filter - both policies still come back' );
}

# --- an explicit empty string IS a real filter value, not "no filter" -----
# --- (Codex review: --ref '' has to be able to ask for board-wide-only) ---

{
    my $scoped = $tira->policy_add( project => $root, rule => 'checklist-unmoved', ref => 'TKT-1', action => 'bridge-reminder' );
    my $board_wide_only = $tira->policy_list( project => $root, ref => '' );
    ok( !( grep { $_->{id} eq $scoped->{id} } @{$board_wide_only} ),
        "--ref '' excludes a ref-scoped policy - it filters for board-wide ones, it is not treated as absent" );
}

done_testing;

__END__

=head1 NAME

1153-a-filter-that-answered-with-everything.t - policy_list actually
filters by the options its own CLI parser accepts

=head1 DESCRIPTION

TKT-646. C<policy_list> took C<%args> and returned every declared policy
regardless of what was in it - C<--rule>, C<--id>, C<--action>,
C<--column>, C<--ref>, C<--enter> and C<--age> all parsed successfully and
were then silently discarded. Now filtered by every field a policy
record actually carries, checked on definedness rather than non-emptiness
so an explicit empty string is itself a real filter value. C<--author> is
deliberately not among these and never refused either: it is not a
caller-supplied filter at all, it is the ambient write-attribution key
C<$ENV{TIRA_AUTHOR}> adds to essentially every command's C<%args>.

=cut
