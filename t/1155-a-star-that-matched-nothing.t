#!/usr/bin/env perl
# TKT-1155. _touch_pattern_matches (lib/Tira/CLI/Serve.pm) has two branches:
# a slash-containing pattern is turned into an anchored regex (wildcards
# substituted, since TKT-1146), but a slash-free (basename-only) pattern is
# compared to the path's basename with plain string eq - no wildcard
# substitution at all. A basename pattern containing '*' (e.g. '*.pm') could
# therefore only match a basename that was literally the four-character
# string '*.pm', not match ordinary .pm files by wildcard as intended.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
require Tira::CLI::Serve;

# --- THE BUG: a wildcard in a slash-free pattern never matches -----------

ok( Tira::CLI::Serve::_touch_pattern_matches( 'lib/Tira/DashboardWeb.pm', '*.pm' ),
    "this ticket's own named example: '*.pm' matches a .pm file by basename" )
  or diag('_touch_pattern_matches wrongly returned false - no wildcard substitution in the slash-free branch');

ok( Tira::CLI::Serve::_touch_pattern_matches( 'lib/Tira.pm', '*.pm' ),
    'and matches regardless of directory depth, since the pattern is slash-free' );

# --- a non-matching extension still does not match ------------------------

ok( !Tira::CLI::Serve::_touch_pattern_matches( 'lib/Tira/DashboardWeb.pod', '*.pm' ),
    'a basename that does not end in .pm still does not match' );

# --- anchoring: the wildcard basename match is exact, not a prefix --------

ok( !Tira::CLI::Serve::_touch_pattern_matches( 'lib/Tira/DashboardWeb.pm.bak', '*.pm' ),
    'a basename merely prefixed by the matched shape does not match' );

# --- a literal (non-wildcard) slash-free pattern is unaffected ------------

ok( Tira::CLI::Serve::_touch_pattern_matches( 'lib/Tira/DashboardWeb.pm', 'DashboardWeb.pm' ),
    'a literal basename-only pattern still matches anywhere in the tree, unchanged' );
ok( !Tira::CLI::Serve::_touch_pattern_matches( 'lib/Tira/DashboardWeb.pm.bak', 'DashboardWeb.pm' ),
    'and still does not match a file merely prefixed by the basename, unchanged' );

# --- a slash-containing wildcard pattern is unaffected (TKT-1146 behavior) -

ok( Tira::CLI::Serve::_touch_pattern_matches( 'lib/Tira/views/board.html', 'lib/Tira/views/*' ),
    'a slash-containing wildcard pattern still matches, unchanged' );

# --- Codex review: boundary cases the refactor must not break -------------

ok( !Tira::CLI::Serve::_touch_pattern_matches( 'foo.pm', '' ),
    'an empty pattern still refuses, unaffected by the wildcard substitution' );
ok( Tira::CLI::Serve::_touch_pattern_matches( 'foo.pm', '*' ),
    'a lone star matches any non-empty basename' );
ok( Tira::CLI::Serve::_touch_pattern_matches( 'plain.pm', '*.pm' ),
    'a slash-free path (no directory at all) is matched as its own basename' );
ok( Tira::CLI::Serve::_touch_pattern_matches( 'foo+bar.pm', 'foo+*.pm' ),
    'a literal regex metacharacter in the pattern (the +) is quotemeta-protected, not treated as a regex quantifier' );
ok( !Tira::CLI::Serve::_touch_pattern_matches( 'fooXbar.pm', 'foo+*.pm' ),
    'so a path substituting for the literal + does not match' );

done_testing;

__END__

=head1 NAME

1155-a-star-that-matched-nothing.t - a wildcard in a slash-free
(basename-only) touch pattern now matches by basename glob

=head1 DESCRIPTION

TKT-1155. C<_touch_pattern_matches>'s slash-free branch compared a pattern
to the path's basename with plain string equality, so a basename pattern
containing C<*> (e.g. C<*.pm>) could only match a basename literally named
that four-character string, not match ordinary C<.pm> files by wildcard as
intended. The slash-free branch now substitutes C<*> into an anchored
regex the same way the slash-containing branch already does (TKT-1146), so
a wildcard basename pattern matches by glob while a literal basename
pattern is unaffected.

=cut
