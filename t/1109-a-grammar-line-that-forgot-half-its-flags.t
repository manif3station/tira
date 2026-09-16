#!/usr/bin/env perl
# TKT-819. SKILLS.md's grammar catalogue names tira.tasklist.list's own
# invocation shape - the agent-facing manual _usage() falls back to when no
# richer description exists. It once read only
# '[--session ID] [--ref REF] [--sort FIELD:DIR[,FIELD:DIR...]] [-o FORMAT]',
# missing --all-sessions (TKT-539), --status (TKT-545) and --unlinked
# (TKT-552) - all three real, documented in docs/commands.md, and reachable
# by an agent who reads only SKILLS.md.
#
# ALREADY FIXED BEFORE THIS TICKET WAS WORKED: TKT-1048 (commit 7e5f376)
# already added all three flags to the grammar line. This ticket's own
# premise was stale by the time it was picked up - confirmed against git
# history rather than assumed. What was actually missing was a regression
# test: nothing guarded this line against drifting again, and this file is
# that guard.

use strict;
use warnings;

use File::Spec;
use FindBin;
use Test::More;

my $skills = File::Spec->catfile( $FindBin::Bin, File::Spec->updir, 'SKILLS.md' );
open my $fh, '<', $skills or die "Cannot read '$skills': $!";
my @lines = <$fh>;
close $fh;

my ($grammar) = grep { /\Atira\.tasklist\.list\s/ } @lines;
ok( defined $grammar, "SKILLS.md carries a tira.tasklist.list grammar line" )
  or diag "not found in $skills";

for my $flag (qw(--session --all-sessions --status --unlinked --ref --sort)) {

    # A trailing boundary, not a bare substring match - Codex review caught
    # that --status/--sort would also match on --status-name/--sorter, which
    # this line does not carry today but a later drift plausibly could.
    like( $grammar // '', qr/\Q$flag\E(?![\w-])/,
        "the grammar line names $flag - an agent reading only SKILLS.md still knows this flag exists" );
}

done_testing;

__END__

=head1 NAME

1109-a-grammar-line-that-forgot-half-its-flags.t - SKILLS.md names every real tasklist.list flag

=head1 WHY

TKT-819: SKILLS.md's tasklist.list grammar line once missed --all-sessions,
--status and --unlinked - all three real flags, documented correctly in
docs/commands.md but absent from the agent-facing manual _usage() falls
back to. TKT-1048 already fixed the line itself before this ticket was
picked up; this test is the regression guard that did not exist before it.

=head1 WHAT IS ASSERTED

SKILLS.md carries a tira.tasklist.list grammar line, and it names every one
of the six real flags the command accepts.

=cut
