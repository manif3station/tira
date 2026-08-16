#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'table' );
my $tira = Tira->new( clock => sub { '2026-08-06T13:10:00+0100' } );
$tira->create_project( name => 'Table project', dir => $root );
$tira->column_add( project => $root, type => 'ticket', name => 'in-progress', before => 'discard' );
$tira->create_record( project => $root, type => 'sow', title => 'Strategy' );
$tira->create_record( project => $root, type => 'epic', title => 'Experience' );
$tira->create_record( project => $root, type => 'ticket', title => '<script>alert("x")</script>' );

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => $command, argv => \@argv, tira => $tira );
    return ( $status, $out, $err );
}

my ( $status, $html, $err ) = cli( 'dashboard', '--title', '-o', 'table' );
is( $status, 0, 'combined table dashboard succeeds' );
is( $err, '', 'combined table dashboard has no stderr' );
like( $html, qr/\A<!doctype html>/i, 'table output is a raw HTML document' );
like( $html, qr/<style>.*linear-gradient/s, 'table embeds a styled gradient surface' );
like( $html, qr/<script>.*onclick/s, 'table embeds local interaction JavaScript' );
like( $html, qr/data-sort="mtime".*data-sort="ref"/s, 'table provides mtime and ref sorting controls' );
like( $html, qr{<title>Table project :: Kanban :: 3</title>},
    'the tab reads project, board and card count; all three boards read as Kanban' );
unlike( $html, qr{<title>Tira Kanban</title>}, 'and no longer shows the generic product name' );
like( $html, qr/class="refresh-status"/, 'table displays its active refresh interval' );
like( $html, qr/>Refresh 60s</, 'the default refresh interval is 60 seconds' );
like( $html, qr/Math\.max\(1,Number\(rawRefresh\)\):60;/,
    'the script falls back to the 60-second default for missing or invalid values' );
is( scalar( () = $html =~ /class="widther"/g ), 3,
    'every board header offers the column-width toggle' );
like( $html, qr/data-width="standard" class="is-active"/, 'standard width is the shipped default' );
like( $html, qr/data-width="fit"/, 'fit-all is the alternative' );
like( $html, qr/localStorage\.setItem\(widthStorageKey/, 'the width choice persists to browser storage' );
like( $html, qr/localStorage\.getItem\(widthStorageKey/, 'the stored width choice is read back on load' );
like( $html, qr/catch\(error\)\{return null\}/, 'unavailable storage degrades to the default rather than failing' );
like( $html, qr/html\[data-width="fit"\] \.board__columns\{display:grid/,
    'fit mode lays the columns out as a grid, so they can wrap onto more than one row' );
like( $html, qr/repeat\(auto-fill,minmax\(14rem,1fr\)\)/,
    'wrapping at a readable minimum width instead of squeezing every column onto one row' );
like( $html, qr/\.column__head\{position:sticky/,
    'and each column keeps its own sticky heading, now that it owns one' );
like( $html, qr/\@media\(max-width:720px\)\{html\[data-width="fit"\] \.board__scroll\{overflow-x:auto\}/,
    'narrow screens keep scrollable columns while the preference is preserved' );
is( scalar( () = $html =~ /class="column__count"/g ), 7,
    'every rendered column carries a count badge, Discard now among them: two on each of sow and epic, three on ticket' );
like( $html, qr/class="column column--discard"/,
    'and Discard is drawn as set aside rather than as live work' );
like( $html, qr/data-count-for="backlog" hidden/, 'count badges start hidden and are filled from the board' );
like( $html, qr/badge\.hidden=total===0/, 'an empty column shows no zero' );
like( $html, qr/badge\.textContent=total\?String\(total\):""/, 'a populated column shows its number' );
unlike( $html, qr/class="column__add"/,
    'static output renders no add-card control: it has no server to post to' );
like( $html, qr/class="last-updated"/, 'table displays when its data was last updated' );
like( $html, qr/URLSearchParams.*refresh.*location\.reload.*setTimeout/s,
    'table embeds query-controlled automatic reload logic' );
is( scalar( () = $html =~ /class="board board--/g ), 3, 'combined dashboard stacks three type boards' );
like( $html, qr/data-type="sow".*data-type="epic".*data-type="ticket"/s,
    'combined dashboard preserves SOW, epic, ticket vertical order' );
like( $html, qr/class="column__name">backlog<.*class="column__name">in-progress</s,
    'ticket columns render left to right' );
like( $html, qr/&lt;script&gt;alert\(&quot;x&quot;\)&lt;\/script&gt;/,
    'record titles are HTML escaped' );
unlike( $html, qr/<script>alert/, 'record data cannot inject executable HTML' );
unlike( $html, qr/<(?:link|img|iframe)\b|https?:\/\//i, 'table has no external resources' );

# The renderer has no `use utf8`, so a literal glyph in the embedded
# script is read as bytes and encoded a second time on the way out, reaching
# the browser as mojibake. Escapes are the only safe way to write one.
for my $rendering (
    [ static => $html ],
    [ live => $tira->format_output(
            $tira->dashboard( project => $root ), output => 'table', project => $root, live => 1 ) ],
) {
    my ( $kind, $document ) = @{$rendering};
    my ($script) = $document =~ /<script>(.*)<\/script>/s;
    ok( defined $script, "the $kind dashboard embeds a script" );
    is_deeply( [ $script =~ /([^\x00-\x7f])/g ], [],
        "the $kind script is pure ASCII, so no glyph can reach the browser double-encoded" );
    my ($style) = $document =~ /<style>(.*)<\/style>/s;
    is_deeply( [ $style =~ /([^\x00-\x7f])/g ], [], "and so is the $kind stylesheet" );
}

( $status, $html, $err ) = cli( 'dashboard.ticket', '-o', 'table' );
is( $status, 0, 'type-specific table dashboard succeeds' );
is( scalar( () = $html =~ /class="board board--/g ), 1, 'type-specific command renders one board' );
like( $html, qr/data-type="ticket"/, 'ticket command renders ticket board' );
unlike( $html, qr/data-type="(?:sow|epic)"/, 'ticket command excludes other boards' );
like( $html, qr{<title>Table project :: Tickets :: 1</title>},
    'a single-type board names that board in the tab' );
like( $html, qr/data-mtime="\d+"/, 'table embeds filesystem mtime for local sorting' );
unlike( $html, qr/<span class="card__title">/, 'table remains ref-only without title flag' );

( $status, my $out, $err ) = cli( 'project.show', '-o', 'table' );
is( $status, 2, 'table output is rejected outside dashboard commands' );
is( $out, '', 'rejected table output emits no stdout' );
like( $err, qr/Table output is available only for dashboard commands/,
    'rejection explains the table scope' );
eval { $tira->format_output( { unrelated => 1 }, output => 'table' ) };
like( $@, qr/Table output requires dashboard data/, 'renderer rejects non-dashboard data directly' );

done_testing;

__END__

=head1 NAME

16-dashboard-table.t - Self-contained Tira Kanban table output

=head1 DESCRIPTION

Guards combined and type-specific raw HTML rendering, board/column order,
embedded styling and interaction, escaping, offline behavior, and output scope
for.

=cut
