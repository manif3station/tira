#!/usr/bin/env perl
# The dashboard has no view layer, and this file says so until it does.
#
# Dancer2 serves the board and Starman runs it, but no template engine is
# configured at all: the HTML, the CSS and the entire front-end are built as
# Perl strings inside lib/Tira.pm. The owner asked for an MVC shape with
# Template Toolkit as the View, to trim the size of the module. TKT-703.
#
# The cost is not aesthetic. Eight lines in lib/Tira.pm are longer than 2,000
# characters and hold 113,884 bytes between them; the longest is 54,419 bytes
# and is the dashboard's JavaScript. A line that long cannot be reviewed in a
# diff, cannot be blamed usefully, and cannot be edited by hand - every
# dashboard change made on TKT-645 tonight was a scripted replace against an
# exact substring, because there is no other safe way to touch it. It also
# means one file holds both a police rule and the colour of a highlighted
# keyword.
#
# This is a red test, and it is red on purpose until the move is made. It is
# deliberately NOT committed with TKT-645: a failing file in t/ turns every
# other card's verify run red, so it stays in the working tree until the work
# that makes it green is done.
#
# The last assertion is the one that must never go red. A view layer is the
# most likely thing to start pulling assets over the network, and the board
# being self-contained is load-bearing - TKT-645 could not use a CDN
# highlighter because of it. That property is asserted here BEFORE the move,
# so the file measures the same thing on both sides of it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $module = 'lib/Tira.pm';
open my $fh, '<', $module or die "cannot read $module: $!";
my $source = do { local $/; <$fh> };
close $fh;

# Every denial below is about this text. A denial about a file that failed to
# load passes while measuring nothing, which is t/147's whole subject.
ok( $source, "$module was read - " . length($source) . ' bytes' );

my @lines = split /\n/, $source;
my @long = grep { length( $lines[$_] ) > 2_000 } 0 .. $#lines;
my $held = 0;
$held += length( $lines[$_] ) for @long;
my ($longest) = sort { length( $lines[$b] ) <=> length( $lines[$a] ) } @long;

is( scalar @long, 0,
    'no line in lib/Tira.pm is longer than 2,000 characters - '
      . scalar(@long)
      . ' are, holding '
      . $held
      . ' bytes, the longest being line '
      . ( defined $longest ? $longest + 1 : 0 ) . ' at '
      . ( defined $longest ? length( $lines[$longest] ) : 0 )
      . ' bytes' );

# The markup itself. Named markers rather than a size, because the module may
# legitimately keep short strings; what must leave is the page.
my @markup = grep { index( $source, $_ ) >= 0 }
  ( '<!doctype html', '<!DOCTYPE html', 'class="card-dialog', '<style>' );
is_deeply( \@markup, [],
    'lib/Tira.pm carries no page markup of its own - it still holds: '
      . ( join ', ', @markup ) );

# Where the View has to live. A directory that ships with the skill, found
# from the module rather than from wherever the process happened to start -
# the same problem tools/card-holes solved for its entrypoints, and the reason
# an installed copy must be able to find it.
my @dirs = grep { -d } qw(views templates lib/Tira/views);
ok( scalar @dirs,
    'the skill ships a template directory - looked for views, templates and '
      . 'lib/Tira/views, found ' . ( @dirs ? join( ', ', @dirs ) : 'none' ) );

# The engine, which is absent entirely rather than merely unused.
open my $web, '<', 'lib/Tira/DashboardWeb.pm'
  or die "cannot read lib/Tira/DashboardWeb.pm: $!";
my $app = do { local $/; <$web> };
close $web;
ok( $app, 'lib/Tira/DashboardWeb.pm was read - ' . length($app) . ' bytes' );
like( $app, qr/template[_ ]?toolkit/i,
    'the Dancer2 app configures a Template Toolkit engine' );

open my $deps, '<', 'cpanfile' or die "cannot read cpanfile: $!";
my $cpanfile = do { local $/; <$deps> };
close $deps;
ok( $cpanfile, 'cpanfile was read - ' . length($cpanfile) . ' bytes' );
like( $cpanfile, qr/Template/,
    'Template Toolkit is a declared dependency, so an installed skill gets it' );

# --- the property the move must not cost -------------------------------------
#
# Green now and green after. If a view layer ever starts pulling an asset, this
# is where it shows, and it is measured on a page that was really rendered
# rather than on an empty string - a clean answer about nothing is the easiest
# false green there is, and this exact check once passed over a 0-byte page.

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-28T08:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name          => 'A dashboard with no view layer',
    dir           => $root,
    members       => ['michael'],
    columns       => ['backlog, implement, done'],
    sow_prefix    => 'AVS',
    epic_prefix   => 'AVE',
    ticket_prefix => 'AVT',
);
$tira->create_record(
    project => $root, type => 'ticket', title => 'Something to render' );

my $data = $tira->dashboard( project => $root, with_title => 1 );
my $page = $tira->format_output( $data,
    output => 'table', project => $root, live => 1, with_title => 1 );

ok( length($page) > 5_000,
    'the served page is a whole dashboard - ' . length($page) . ' bytes' );

my @external = $page =~ m{(?:src|href)\s*=\s*["'](https?:|//)}gi;
is( scalar @external, 0,
    'the board still requests nothing over the network - '
      . scalar(@external)
      . ' external references in the rendered page' );

done_testing();

__END__

=head1 NAME

t/426-a-dashboard-with-no-view-layer.t - the dashboard must render through a
view layer rather than from Perl strings

=head1 DESCRIPTION

Dancer2 serves the board and Starman runs it, and no template engine is
configured at all. The page, its stylesheet and its whole front-end are built
as Perl strings inside C<lib/Tira.pm>, which is 14,613 lines and 837,174 bytes.
Eight of those lines are longer than 2,000 characters and hold 113,884 bytes
between them; the longest is 54,419 bytes and is the dashboard's JavaScript.

The owner asked for an MVC shape with Template Toolkit as the View, to trim the
module down. The reason it matters is reviewability: a 54KB line cannot be read
in a diff or blamed usefully, and every dashboard change on TKT-645 was made by
a scripted replace against an exact substring because nothing else was safe.

This file is red until that move is made, and it is deliberately not committed
alongside TKT-645 - a failing file in C<t/> turns every other card's verify run
red, so it lives in the working tree until the work that greens it is done.

The last two assertions are green now and must stay green. A view layer is the
most likely thing to start fetching assets, and a board that makes no network
requests is load-bearing here: TKT-645 shipped an embedded 4.5KB tokeniser
rather than a CDN highlighter for exactly that reason. They are measured on a
page that was really rendered, because this same check once reported a clean
result over a page that was zero bytes long.

=cut
