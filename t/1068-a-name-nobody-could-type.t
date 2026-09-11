#!/usr/bin/env perl
# TKT-577. docs/commands.md and SKILLS.md both named `record.show` as a
# runnable command in the passages describing the "multiple --ref" guard
# in lib/Tira/CLI.pm - it is not: there is no `cli/record/show` entrypoint,
# and `d2 tira.record.show --ref REF` answers "Command 'record.show' not
# found in skill 'tira'". `record.show` is the INTERNAL $command value the
# entrypoint scripts for `ticket.show`/`epic.show`/`sow.show` all resolve
# to - real, but never typed directly, the same asymmetry `record.create`
# and `record.update` already have.
#
# docs/commands.md:3774 compounded this with an arithmetic self-contradiction:
# it named `record.show` and `tasklist.next` as two commands already allowed
# multiple refs, then called `release.record` "the second command after"
# them - which would make it the third, not the second, if the count started
# there. And its sibling entries (3858, 4081) both describe the guard as
# covering only `record.show`/`tasklist.next`/`release.record`, uncorrected
# by the 5.89 extension (TKT-791) that added `notify.record` and
# `tasklist.task.ref.link`/`.unlink` to the same whitelist - stated
# accurately elsewhere in the same file, so the guard's own real membership
# was never in question, only whether every passage naming it agreed.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read '$path': $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

# --- the real membership, read from the guard itself, not assumed ----------

use lib 'lib';
use lib 't/lib';
use Suite ();

my $cli_source = Suite::cli_source('CLI.pm');
my ($guard_regex) = $cli_source =~ /Multiple refs are only available on show.*?\n\s*if\s+\$command\s*!~\s*\/\\A\(\?:(.*?)\)\\z\//s;
ok( $guard_regex, 'the multi-ref guard regex is where this test expects it' );

my @members = split /\|/, $guard_regex;
is( scalar @members, 5,
    'the guard names 5 alternatives (record.show, tasklist.next, release.record, notify.record, and one entry covering both tasklist.task.ref.link/unlink)'
) or diag "members: @members";

# --- no document tells a reader to run record.show as if it dispatches -----

for my $doc (qw(docs/commands.md SKILLS.md)) {
    my $text = slurp($doc);
    ok( $text, "$doc was read - not empty, not truncated" );

    # The specific self-contradictory phrasing this ticket found - a fixed
    # ordinal claim ("the second command after X and Y") that does not
    # survive a third name being added to the set it counts.
    unlike( $text, qr/second command after `?record\.show`?/,
        "$doc no longer claims release.record is 'the second command after record.show'" );

    # A stale "only two"/"the two commands" claim tied to this guard, left
    # uncorrected by the 5.89 extension documented elsewhere in the same
    # file - checked close to "record.show" itself (a few hundred
    # characters, not the whole file) so an unrelated "only two commands"
    # phrase elsewhere in the document cannot cause a false match.
    unlike( $text, qr/(?:only two commands|the two commands allowed)[^.]{0,200}record\.show|record\.show[^.]{0,200}(?:only two commands|the two commands allowed)/s,
        "$doc does not claim only two commands are allowed multiple refs" );
}

# --- the corrected passages name what a reader can actually type -----------

my $commands_md = slurp('docs/commands.md');
like( $commands_md, qr/ticket\.show.*epic\.show.*sow\.show/s,
    'docs/commands.md names the real, typeable show verbs (ticket.show/epic.show/sow.show) somewhere in the multi-ref discussion' )
  or like( $commands_md, qr/tira\.TYPE\.show/,
    'or names them via the TYPE placeholder the record section already uses' );

done_testing;

__END__

=head1 NAME

t/1068-a-name-nobody-could-type.t - docs describing the multi-ref guard name
what a reader can actually type, and the count agrees with the guard itself

=head1 DESCRIPTION

TKT-577. `record.show` is a real internal command value - what
`ticket.show`/`epic.show`/`sow.show` each resolve to - but never a name a
reader can type at the CLI (`d2 tira.record.show` answers "Command
'record.show' not found"). The passages describing
lib/Tira/CLI.pm's "Multiple refs are only available on show" guard read as
if it were, and one of them arithmetically miscounted its own membership by
calling a third command "the second" after two others already named. Fixed
to name the real show verbs and drop the self-contradictory ordinal claim,
verified against the guard's own regex rather than a second hand-copied
count.

=cut
