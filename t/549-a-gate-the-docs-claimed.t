#!/usr/bin/env perl
# docs/commands.md claimed a verify-column browser-test gate that was never
# actually added to a project's column configuration.
#
# TKT-799. Found via a fresh project's own verify column: its required
# actions carry no browser/Playwright-relevant item, while docs/commands.md
# said since 4.99 this ran "as a conditional required action on the verify
# column" - stated as an accomplished fact rather than the aspiration it
# actually was.
#
# Corrected the doc to say so honestly and filed TKT-936 to build the real
# gate. This guards the corrected claim: a fresh project's verify column has
# no browser-relevant required action today, matching what the doc now says.
# Once TKT-936 ships the real gate, this assertion is expected to flip, and
# whoever does that work should update docs/commands.md's claim in the same
# commit - t/03-metadata.t's own changelog check is the discipline for that,
# not a second guard invented here.
#
# WRITTEN RED, against the pre-fix doc text.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

# --- the doc is honest about the gate's real state ---------------------------

open my $fh, '<', 'docs/commands.md' or die "docs/commands.md: $!";
my $docs = do { local $/; <$fh> };
close $fh;

like( $docs, qr/was never actually added/,
    'DOCS/COMMANDS.MD SAYS THE GATE WAS NEVER ADDED - not that it exists, '
      . 'which is what a fresh board below proves' );

# --- and a fresh board's own verify column agrees --------------------------

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new;
$tira->project_new(
    project => $root, name => 'Fresh', dir => $root, members => ['claude'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'FRS', epic_prefix => 'FRE', ticket_prefix => 'FRT',
);
my ($verify) = grep { $_->{name} eq 'verify' }
  @{ $tira->column_list( project => $root, type => 'ticket' ) };

my @browser_relevant = grep { /browser|playwright/i }
  @{ $verify->{required_actions} // [] };
is_deeply( \@browser_relevant, [],
    "A FRESH BOARD'S OWN VERIFY COLUMN CARRIES NO BROWSER-RELEVANT REQUIRED "
      . 'ACTION - matching what the doc now says rather than what it used '
      . 'to claim. This is not the project board configuration TKT-799 '
      . "found - it is Tira's own out-of-the-box column defaults, which "
      . "never had this gate either" );

done_testing();

__END__

=head1 NAME

549-a-gate-the-docs-claimed.t - docs/commands.md said the verify column had a browser-test gate it never actually got

=head1 WHY

TKT-799. docs/commands.md stated, as an accomplished fact since 4.99, that
the verify column carries a conditional required action prompting
C<tools/browser-tests> for browser-relevant changes. No such item exists in
this board's column configuration, and none exists in Tira's own default
column templates either.

=head1 WHAT IS ASSERTED

That the doc now says the gate was never added, and that a freshly created
project's verify column genuinely carries no browser-relevant required
action - consistent with the corrected claim.

=cut
