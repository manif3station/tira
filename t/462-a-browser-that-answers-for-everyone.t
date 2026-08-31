#!/usr/bin/env perl
# TKT-796. tools/hooks/pre-push ran tools/browser-tests (21 Playwright
# checks) once per PUSH, which can carry many cards batched together - a
# single flaky browser test (TKT-675) blocked the entire batch even though
# every card in it had individually passed its own verify gate. The
# owner's own words: "Browser test should be a separate column and not
# mix with pushing. When card reaches to push column should be already
# fully tested." Refined when asked whether every card needs it: "not all
# cards need browser test... browser is deterministic... dynamically" -
# not a blanket check, one that fires only when a card's own changes
# touch a browser-relevant file.
#
# So the check moves out of this repo's own push hook (once per batch,
# CI-shaped) to a project's verify column - a per-project, per-card gate
# configured with `d2 tira.column.update --required-action`, the same
# way pending-push's own entry-required-action was reworded earlier this
# session. Column required_actions are project data (column_list reads
# config->{columns}, not a hard-coded engine default - see lib/Tira.pm's
# _column_defaults/column_list), so this file only proves the half that
# IS shipped code: the push hook no longer runs the browser suite. The
# board-side required-action wording is a d2 tira.column.update call
# against the live board, recorded on the card rather than tested here.

use strict;
use warnings;

use Test::More;

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

my $hook = slurp('tools/hooks/pre-push');
like( $hook, qr{\A#!/usr/bin/env bash}, 'the push hook is a bash script and was read' );

unlike( $hook, qr{tools/browser-tests\s*(?:\|\||&&|;|\z)},
    'the push hook no longer INVOKES the browser suite - it happens earlier, per card, at verify' );
like( $hook, qr/TKT-796|browser check ran here/,
    'the removal is explained in the hook\'s own comments, not silently deleted' );
unlike( $hook, qr/opening a browser on the board/,
    'and the step announcing it is gone too, not just the command inside it' );

done_testing;

__END__

=head1 NAME

t/462-a-browser-that-answers-for-everyone.t - the browser-test gate moved
from the push hook to the verify column, conditionally

=head1 DESCRIPTION

C<tools/hooks/pre-push> ran the full Playwright suite once per push,
blocking an entire batch of cards on one flaky browser test (TKT-675)
that had nothing to do with most of them. The check moved to a
project's C<verify> column instead (project-side board configuration,
via C<d2 tira.column.update --required-action>, not shipped engine
code), as a conditional item that fires only when a card's changes
touch C<lib/Tira/views/*>, C<DashboardWeb.pm>, or C<OnboardWeb.pm> - a
card that never touches those files satisfies it by saying so. This
file proves the shipped half: the push hook itself no longer runs the
browser suite. TKT-796.

=cut
