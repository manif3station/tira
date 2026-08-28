#!/usr/bin/env perl
# The board's script has to parse.
#
# TKT-645 added a syntax highlighter to the attachment viewer, and one string
# in it wanted a literal backslash. The dashboard's JavaScript is built inside
# a Perl q{} string, where \\ collapses to one backslash - so the file on disk
# read "\\" and the browser was served "\", an escaped quote that never closed
# its string. Every statement after it was garbage.
#
# Nothing in the Perl suite noticed. All 8602 tests passed against a board
# whose script died on load: the page still rendered, still contained every
# element, and every assertion about its markup still held. The dashboard was
# simply dead - no columns, no dialog, no ready flag - and the only thing that
# said so was a browser test in a lab that prove does not run.
#
# So the parse is asserted here, where it is cheap, rather than only there,
# where it is slow and easy to skip. This is not a test about backslashes. It
# is the rule that the page ships a script a browser can actually read, which
# any interpolation mistake in 98KB of hand-built JavaScript can break.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-28T06:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name       => 'A page whose script never ran',
    dir        => $root,
    members    => ['michael'],
    columns    => ['backlog, implement, done'],
    sow_prefix => 'APS',
    epic_prefix => 'APE',
    ticket_prefix => 'APT',
);
$tira->create_record(
    project => $root, type => 'ticket', title => 'Something to render' );

# node is what reads the script. Without it this file proves nothing, so it
# says so and stops rather than passing quietly - the whole point of the test
# is that a green result here means the parse actually happened.
my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp $node;
if ( !$node ) {
    plan skip_all =>
      'node is not installed, so the script was never parsed - this file '
      . 'cannot say whether the page is loadable. It is present in the '
      . 'perl-test container, which is where the suite runs.';
}

my $data = $tira->dashboard( project => $root, with_title => 1 );
my $page = $tira->format_output( $data,
    output => 'table', project => $root, live => 1, with_title => 1 );

# The subject has to exist before a denial about it means anything. A previous
# check of this page reported "no external references" over a page that was
# zero bytes long, because it had asked for it the wrong way.
ok( length($page) > 5_000,
    'the served page is a whole dashboard, not an empty or error render - '
      . length($page)
      . ' bytes' );

my @blocks = $page =~ m{<script[^>]*>(.*?)</script>}gs;
ok( scalar @blocks, 'the served page carries a script block' );

my $script = join "\n;\n", @blocks;
ok( length($script) > 20_000,
    'the script block is the real dashboard script - ' . length($script)
      . ' bytes' );

my $js = File::Spec->catfile( $tmp, 'served.js' );
open my $fh, '>', $js or die "cannot write $js: $!";
print {$fh} $script;
close $fh;

my $stderr = File::Spec->catfile( $tmp, 'node.err' );
system("$node --check '$js' 2>'$stderr'");
my $status = $? >> 8;

my $complaint = '';
if ( open my $err, '<', $stderr ) {
    local $/;
    $complaint = <$err> // '';
    close $err;
}

# Node echoes the offending line, and the dashboard's is one 98KB line. Only
# the diagnosis is wanted here, not the haystack it was found in.
my ($said) = $complaint =~ /^((?:\w+)?Error:.*)$/m;
$said //= ( split /\n/, $complaint )[0] // 'nothing';

is( $status, 0,
    "the served script parses - node said: $said" );

# A failure has to name what broke, or a future reader learns only that
# something did. "\"" is the specific shape this card shipped: a quote that
# escapes itself and swallows the rest of the file.
if ( $status != 0 ) {
    my ($near) = $script =~ /(.{80}\\".{80})/s;
    diag( "the parse failed; node reported:\n" . $complaint );
    diag( "a self-escaping quote appears near:\n" . $near ) if $near;
}

# The fault that prompted this file, pinned where it happened: a backslash
# that has to survive q{} to reach the browser as a backslash.
like( $script, qr/rest\[j\]==="\\\\"/,
    'the string scanner tests for a literal backslash, not for an escaped '
      . 'quote - the q{} that builds this script halves every backslash pair '
      . 'it is given' );

done_testing();

__END__

=head1 NAME

t/424-a-page-whose-script-never-ran.t - the board must ship a script a browser
can read

=head1 DESCRIPTION

TKT-645 added a syntax highlighter to the attachment viewer. One string in it
wanted a literal backslash, and the dashboard's JavaScript is built inside a
Perl C<q{}>, where a backslash pair collapses to one - so the file on disk read
correctly and the browser was served a quote that escaped itself and never
closed. Every statement after it was garbage.

Nothing in the Perl suite noticed. All 8,602 tests passed against a board whose
script died on load: the page still rendered, still contained every element,
and every assertion about its markup still held. The dashboard was simply dead,
and the only thing that said so was a browser test in a lab C<prove> does not
run - which failed for a card that had nothing to do with the change.

So the parse is asserted here, where it is cheap. This is not a test about
backslashes; it is the rule that the page ships a script a browser can actually
read, which any interpolation mistake in 98KB of hand-built JavaScript can
break.

The page is measured before it is parsed, because a check over an empty render
would report a clean parse about nothing. C<node> is required rather than
skipped past: a green result here has to mean the parse happened.

=cut
