#!/usr/bin/env perl
# The board's own voice is readable only from a terminal.
#
# TKT-916, EPC-014. His report 6799: "Where is the terminal log windows to
# display and tail last 100 lines of the violation logs?"
#
# HE IS ASKING WHERE IT IS, and the card made establishing that its first
# criterion. The answer is that the mechanism exists and is pointed at a
# different log:
#
#   lib/Tira/views/logs-panel.js and DashboardWeb's /logs route are TKT-852's
#   panel, built when the dashboard would not load for him and nothing could
#   say whether requests were arriving. They show REQUESTS THAT REACHED THE
#   SERVER - method, path, status - and the panel says on screen what it cannot
#   tell you: a page that never reaches the server leaves nothing in it.
#
# So the place is decided and the shape is built. What is missing is the police
# bridge: the stream tira.policy.bridge.logs reads, which is where a board says
# what it has found and what has settled. Nothing renders it, so somebody
# watching the board in a browser has to open a terminal to hear it - which is
# the one place they are not already looking.
#
# THE SOURCE IS THE ENGINE'S, NOT A SECOND READER. tira.policy.bridge.logs goes
# through Tira::enforcement_log, and the panel must go through the same sub
# rather than reading bridge.log itself. Two readers of one file drift - the
# same rule that keeps the schedule words and a monitor's liveness in the
# engine, and the reason the header reads `running` rather than a pid.
#
# A HUNDRED LINES IS HIS NUMBER, and it is a panel rather than a whole file.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;

my ( $tira, $root, $store );
{
    my $tmp = tempdir( CLEANUP => 1 );
    $root = File::Spec->catdir( $tmp, 'board' );
    $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Bridge', dir => $root,
        members => ['claude'], columns => ['backlog, done'],
        sow_prefix => 'BRS', epic_prefix => 'BRE', ticket_prefix => 'BRT',
    );
    require Tira::CLI::Police;
    $store = Tira::CLI::Police::_police_store($root);
}

# --- the stream exists and the engine reads it -------------------------------
#
# The control, and it passes before the change: what the panel needs is already
# readable through one sub, and that sub is what the CLI verb calls.

can_ok( 'Tira', 'enforcement_log' );

# AND THE CLI VERB GOES THROUGH IT, which is what makes it the source rather
# than one of two. Asserted against the command surface, walked rather than
# named (t/486).
{
    my $cli = Suite::cli_source();

    like( $cli, qr/policy\.bridge\.logs/,
        'tira.policy.bridge.logs is a command the surface knows' );

    like( $cli, qr/enforcement_log\(/,
        'and it answers by calling enforcement_log - so a panel that called '
          . 'anything else would be a second reader of one stream, which is '
          . 'how the engine and the browser came to disagree about attachment '
          . 'content types (TKT-713)' );
}

# WHAT IS NOT ASSERTED HERE, and the first version of this file got it wrong:
# that a hand-written bridge_write turns up in enforcement_log. It does not,
# and the reason is worth knowing rather than working around - bridge_write
# appends to the STREAM, while enforcement_log reads the LEDGER's entries,
# which a police pass writes. A fixture that conflates the two reports the
# stream as unreadable and blames the product for the test's mistake.

# --- what the page offers today ----------------------------------------------

my $render = Suite::engine_source();

like( $render, qr/board--logs/,
    'THE PANEL MECHANISM IS BUILT. TKT-852 put a logs section in the page and '
      . 'a route behind it, which is why this card is a feature request rather '
      . 'than a defect - the answer to "where is it" is that it exists and is '
      . 'pointed at the request log' );

# THE CLAIM.
like( $render, qr/board--bridge/,
    'AND THERE IS A SECTION FOR THE BRIDGE, which there is not today. The '
      . 'board says what it has found through a stream nobody watching the '
      . 'page can see, so it is read in a terminal or not at all - and the '
      . 'terminal is the one place he is not already looking' );

# SCOPED TO THE ROUTE, because enforcement_log is DEFINED in the engine source
# and a whole-file match would pass against a route that never calls it - an
# assertion that cannot fail is worth less than none.
my ($route) = Suite::engine_source() =~ /(get \s* '\/bridge' \s* => .*?\n \};)/xs;

ok( defined $route && length $route,
    'a route of its own serves it, beside the one the request panel uses' );

like( $route // '', qr/enforcement_log/,
    'AND IT READS THE ENGINE\'S OWN STREAM rather than opening bridge.log for '
      . 'itself' );

# --- and the panel itself -----------------------------------------------------

my $panel = eval { Suite::view_source('bridge-panel.js') };

ok( defined $panel && length $panel,
    'there is a script that renders it - by basename through Suite, so it '
      . 'survives the views directory moving (t/486, widened on TKT-921)' );

SKIP: {
    skip 'no bridge panel yet', 2 if !defined $panel;

    like( $panel, qr/fetch\(\s*"\/bridge"/,
        'which asks the route for the stream' );

    like( $panel, qr/\b100\b/,
        'and a hundred lines is the default, which is his number and is a '
          . 'panel rather than a whole file' );
}

done_testing();

__END__

=head1 NAME

541-a-bridge-nobody-can-see-from-the-page.t - the police bridge, in the browser

=head1 WHY

TKT-916, his report 6799. The police bridge is where a board says what it has
found and what has settled, and nothing renders it: somebody watching the board
in a browser must open a terminal to hear it.

The card's first criterion was to establish whether such a view already exists.
It does, for a different log - F<logs-panel.js> and C</logs> are TKT-852's
request panel, which shows what reached the server. So the place and the shape
are settled and the source is missing, which makes this a feature request.

=head1 WHAT IS ASSERTED

First the control: the stream is readable through C<Tira::enforcement_log>, the
same call C<tira.policy.bridge.logs> makes - so the panel has one source to use
rather than a second reader of C<bridge.log>, which is how the engine and the
browser once came to disagree about attachment content types.

Then: that a bridge section is rendered, that a route serves it, that it reads
the engine's stream, and that the panel asks for it with a default of a hundred
lines - his number.

=head1 WHAT IS NOT ASSERTED

That it looks right, or that it follows new lines in a real browser. This suite
drives none; browser checks are his.

=cut
