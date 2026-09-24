#!/usr/bin/env perl
# TKT-1146. _touch_pattern_matches (lib/Tira/CLI/Serve.pm) builds its
# slash-containing-pattern regex with only a start anchor: the pattern is
# quotemeta'd, its '*' turned into '.*', and matched with \A but no \z. A
# literal (non-wildcard) pattern with a '/' in it therefore matches any path
# it is merely a PREFIX of, not only an exact match -
# _touch_pattern_matches('docs/commands.md.bak', 'docs/commands.md') is
# wrongly true today.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
require Tira::CLI::Serve;

# --- THE BUG: a literal slash-containing pattern matches a path it is only
# --- a prefix of --------------------------------------------------------

ok( !Tira::CLI::Serve::_touch_pattern_matches( 'docs/commands.md.bak', 'docs/commands.md' ),
    'a literal pattern does not match a path it is merely a prefix of' )
  or diag('_touch_pattern_matches wrongly returned true - the missing \z end-anchor');

ok( !Tira::CLI::Serve::_touch_pattern_matches( 'docs/commands.mdx', 'docs/commands.md' ),
    'nor a path that only shares the pattern as a prefix with extra suffix characters' );

ok( !Tira::CLI::Serve::_touch_pattern_matches( 'docs/commands.md/subdir/file', 'docs/commands.md' ),
    'nor a path that continues into a subdirectory of the same name' );

ok( !Tira::CLI::Serve::_touch_pattern_matches( 'lib/Tira.pm.bak', 'lib/Tira.pm' ),
    "this ticket's own named example: lib/Tira.pm.bak is not lib/Tira.pm" );

# --- an exact match still works ------------------------------------------

ok( Tira::CLI::Serve::_touch_pattern_matches( 'docs/commands.md', 'docs/commands.md' ),
    'an exact literal match still matches' );

# --- a wildcard pattern is unaffected -------------------------------------

ok( Tira::CLI::Serve::_touch_pattern_matches( 'lib/Tira/views/board.html', 'lib/Tira/views/*' ),
    "a wildcard pattern still matches anything under that prefix" );
ok( Tira::CLI::Serve::_touch_pattern_matches( 'lib/Tira/views/nested/deep.html', 'lib/Tira/views/*' ),
    'including nested paths, since the wildcard already absorbs an end anchor harmlessly' );
ok( !Tira::CLI::Serve::_touch_pattern_matches( 'lib/Tira/other/board.html', 'lib/Tira/views/*' ),
    'and a path outside the wildcarded prefix still does not match' );

# --- a slash-free (basename) pattern is unaffected - it already used exact
# --- string equality -------------------------------------------------------

ok( Tira::CLI::Serve::_touch_pattern_matches( 'lib/Tira/DashboardWeb.pm', 'DashboardWeb.pm' ),
    'a basename-only pattern still matches anywhere in the tree' );
ok( !Tira::CLI::Serve::_touch_pattern_matches( 'lib/Tira/DashboardWeb.pm.bak', 'DashboardWeb.pm' ),
    'and still does not match a file merely prefixed by the basename' );

done_testing;

__END__

=head1 NAME

1146-a-prefix-mistaken-for-a-match.t - _touch_pattern_matches requires an
exact match for a literal slash-containing pattern, not merely a prefix

=head1 DESCRIPTION

TKT-1146. C<_touch_pattern_matches>'s slash-containing-pattern regex had
only a start anchor (C<\A>), so a literal (non-wildcard) pattern matched any
path it was a PREFIX of - C<docs/commands.md> wrongly matched
C<docs/commands.md.bak>, C<docs/commands.mdx>, and
C<docs/commands.md/subdir/file>. A trailing C<\z> now closes the gap; a
wildcard pattern is unaffected, since its own C<.*> substitution already
absorbs the end anchor harmlessly, and the slash-free (basename) branch was
already exact string equality and untouched.

=cut
