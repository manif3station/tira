#!/usr/bin/env perl
# The page offers only what it can do.
#
# The page rendered to disk carried a Columns button and the whole column
# dialog, with neither the script that opens them nor the binding that would.
# Clicking it did nothing. It is the second control found in that state - the
# queue toggles were the first, in the same block - and both were found the
# same way, by a browser test that had never been run.
#
# The queue toggles could simply be bound, because filtering happens in the
# page. This one cannot: editing columns posts to a server, and a page saved to
# disk has none. So the honest fix is not to offer it there.
#
# Written as a rule rather than as a fact about one button, so the next control
# added to that page has to bring its handler with it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T06:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Only what it can do', dir => $root, members => ['michael'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ONS', epic_prefix => 'ONE', ticket_prefix => 'ONT',
);
$tira->create_record( project => $root, type => 'ticket', title => 'Something to look at' );

# Rendered the way the command renders it: the dashboard data, then
# format_output as a table. live is what the served board passes.
my $data = $tira->dashboard( project => $root, with_title => 1 );
my $page = $tira->format_output( $data, output => 'table', project => $root, with_title => 1 );
ok( length $page, 'the page renders' );

# --- every control on it is wired -----------------------------------------
#
# The attribute is how the page marks a control; the binding is the line that
# gives it behaviour. One without the other is a button that looks live and is
# not, which is worse than no button: somebody clicks it and learns nothing.

my @controls = qw(data-width data-sort data-filter data-queue);
for my $control (@controls) {
    like( $page, qr/\Q$control="\E/, "the page offers $control" );
    like( $page, qr/\Q[$control]\E/, "and binds it, so clicking it does something" );
}

# --- and the one it cannot honour is not offered ---------------------------

unlike( $page, qr/data-columns="/,
    'the page saved to disk does not offer a Columns button, because editing columns needs a server it does not have' );
unlike( $page, qr/class="column-dialog/,
    'nor the dialog behind it, which would be a form with nowhere to post' );

# --- while the served board keeps both -------------------------------------
#
# The editor works there and is proved by t/playwright/column-editor.js against
# a real browser. Taking it off the static page must not take it off the board.

my $served = $tira->format_output( $data, output => 'table', project => $root,
    live => 1, with_title => 1 );
like( $served, qr/data-columns="/, 'the served board still offers it' );
like( $served, qr/\[data-columns\]/, 'and still binds it' );

done_testing();

__END__

=head1 NAME

121-no-dead-controls.t - the page offers only what it can do

=head1 DESCRIPTION

The page rendered to disk carried a Columns button and its dialog with nothing
to open them - the second control found in that state, after the queue toggles,
and found the same way.

The toggles could be bound because filtering happens in the page. This one
cannot: editing columns posts to a server that a saved page does not have. So
it is not offered there, and the served board keeps it.

Written as a rule rather than a fact about one button, so the next control
added to that page has to bring its handler with it.

=cut
