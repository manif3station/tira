#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-11T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Gated', dir => $root, members => ['michael'],
    columns => ['Backlog, Doing'],
    sow_prefix => 'GTS', epic_prefix => 'GTE', ticket_prefix => 'GTT',
);

my $page = $tira->login_page_html( name => 'Gated' );

# --- self-contained ------------------------------------------------------

# A board is often run somewhere with no route out to the internet, and a page
# that quietly needs a font or a script from elsewhere works on the machine it
# was written on and nowhere else.
unlike( $page, qr{(?:src|href)\s*=\s*["']?(?:https?:)?//}i,
    'the page loads nothing from another host' );
unlike( $page, qr/\@import/i, 'and imports no stylesheet from anywhere' );
unlike( $page, qr/fonts\.googleapis|cdn\.|unpkg|jsdelivr/i,
    'and names no content delivery network' );

# --- pure ASCII ----------------------------------------------------------

# This renderer has no `use utf8`, so a literal glyph in an embedded
# script is read as bytes and encoded a second time on the way out, reaching
# the browser as mojibake. Escapes are the only safe way to write one.
my ($script) = $page =~ m{<script>(.*)</script>}s;
ok( defined $script, 'the page embeds a script' );
is_deeply( [ $script =~ /([^\x00-\x7f])/g ], [],
    'which is pure ASCII, so no glyph can reach the browser double-encoded' );

my ($style) = $page =~ m{<style>(.*)</style>}s;
ok( defined $style, 'and a stylesheet' );
is_deeply( [ $style =~ /([^\x00-\x7f])/g ], [], 'which is pure ASCII too' );

# --- what it asks for ----------------------------------------------------

like( $page, qr/<input[^>]*id="id_"/, 'there is a box for the name' );
like( $page, qr/<input[^>]*type="password"/, 'and one for the password' );
unlike( $page, qr/<select/i,
    'and no dropdown of people, because he asked for a typed name' );

# --- what it gives away --------------------------------------------------

# The login page is the one thing outside the gate, so a stranger reaching it
# must learn nothing about who is on the project. A list of names is half of a
# login.
$tira->person_add( project => $root, id => 'grace', name => 'Grace Hopper' );
my $fresh = $tira->login_page_html( name => 'Gated' );
like( $fresh, qr/<form|password/i,
    'the page rendered, so the denial below is about a page and not about nothing' );
unlike( $fresh, qr/michael|grace|hopper/i, 'the page names nobody on the project' );

# One message covers both a wrong password and somebody who is not here at
# all, so the page cannot be used to find out who exists.
my @failures = $script =~ /textContent\s*=\s*"([^"]*(?:did not match|not found|unknown|no such)[^"]*)"/gi;
is( scalar @failures, 1, 'there is exactly one message for a failed sign-in' );
unlike( $failures[0] // '', qr/password|user|person|name.*(?:exist|found)/i,
    'and it does not say which half was wrong' );

# --- first visit versus coming back --------------------------------------

like( $page, qr/becomes your password/i,
    'a first-time visitor is told that what they type becomes their password' );
like( $script, qr/\bclaimed\b/,
    'and the page reacts to being told a password was claimed rather than matched' );

# --- the project is named ------------------------------------------------

like( $page, qr/>Gated</, 'the board says which board it is' );
like( $page, qr{<title>[^<]*Gated[^<]*</title>}, 'including in the tab' );

my $escaped = $tira->login_page_html( name => '<script>alert(1)</script>' );
unlike( $escaped, qr/<script>alert/, 'and a project name cannot smuggle markup in' );
like( $escaped, qr/&lt;script&gt;alert/, 'it is escaped instead' );

# --- viewport ------------------------------------------------------------

like( $page, qr/name="viewport"/, 'the page is usable on a phone' );
like( $page, qr/charset="utf-8"/i, 'and declares its encoding' );

done_testing;

__END__

=head1 NAME

78-login-page.t - TKT-005 the one page a stranger can reach

=head1 DESCRIPTION

The login page sits outside the gate, which makes it the only thing an
unknown visitor can look at. That shapes most of what is checked here.

It names nobody. The owner asked for a typed name rather than a dropdown, and
the reason is the same: a list of the people on a project is half of a login,
handed to somebody who has proved nothing. A failed sign-in gets one message
that does not say which half was wrong, so the page cannot be used to find out
who exists.

It is self-contained. No font, stylesheet or script from another host, because
a board is often run somewhere with no route out and a page that quietly needs
the internet works on the machine it was written on and nowhere else.

And it is pure ASCII. This renderer has no C<use utf8>, so a literal glyph in
an embedded script is encoded twice on the way out and reaches the browser as
mojibake - which has already happened here once.

=cut
