#!/usr/bin/env perl
# The column editor's two required-action lists have to be tellable apart.
#
# TKT-591 added the entry list and put it after the exit one, keeping the exit
# list's existing label. The owner saw it for the first time and sent back an
# annotated screenshot: an arrow from the entry block up above the exit block,
# and 'Should the entry action list above the exit ones? And the exit ones
# labeled missing the exit wording too'.
#
# Three faults in his words and a fourth in the picture:
#
#   - the ENTRY list renders below the EXIT one, which is the reverse of the
#     order a card meets them
#   - the exit list is labelled 'Required actions', which was unambiguous when
#     it was the only list and now leaves a reader to infer that the one
#     without a qualifier is the exit one
#   - both add fields say 'Add a required action...', so nothing but position
#     tells them apart
#   - the entry inputs are half width while the exit ones fill the row, because
#     the stylesheet has rules for column-row__action-* and none at all for
#     column-row__entry-action-*
#
# Read rather than driven, the way t/417 and t/423 read the front-end they
# assert about. That is cheap here for a reason worth recording: TKT-703 moved
# this editor out of a 12,203-byte q{} string inside lib/Tira.pm and into
# lib/Tira/views/column-editor.js hours ago, so a test can open the file the
# browser is served. The Playwright half is CHK-004 and belongs in the lab.
#
# The last two assertions are green now and must stay green. Nothing here is
# allowed to change what the editor stores or how it collects the two lists,
# and the fixture drives both by their input classes - so a reorder that
# renamed them would satisfy every assertion above and break the feature.

use strict;
use warnings;

use File::Spec;
use Test::More;

my $views = File::Spec->catdir( 'lib', 'Tira', 'views' );

my $js = do {
    my $path = File::Spec->catfile( $views, 'column-editor.js' );
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    <$fh>;
};
my $css = do {
    my $path = File::Spec->catfile( $views, 'dashboard.css' );
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    <$fh>;
};

# Established before anything is asserted about them. Every claim below is
# about the contents of these two files, and a claim over a file that failed to
# load is true for the wrong reason - t/147's subject, and the thing that made
# t/417 fail loudly rather than quietly when this same code moved.
ok( $js,  'the column editor was read - ' . length($js) . ' bytes' );
ok( $css, 'the stylesheet was read - ' . length($css) . ' bytes' );

# --- the order a card meets them -------------------------------------------

# Asked of the append order itself rather than of two particular call strings.
# The first version of this compared the positions of 'row.append(actionsWrap)'
# and 'row.append(entryActionsWrap)', which reads the order only while the two
# are separate statements - a single row.append(entry, exit) says the same
# thing more directly and that assertion could not see it. What matters is
# which wrap reaches the row first, however the call is written.
my ($appends) = join ' ', $js =~ /row\.append\(([^)]*)\)/g;
like( $appends, qr/ActionsWrap/,
    'the two required-action blocks are appended to the row - ' . $appends );

my $entry_at = index $appends, 'entryActionsWrap';
my $exit_at  = index $appends, 'actionsWrap,';
$exit_at = index $appends, 'actionsWrap' if $exit_at < 0;
# 'entryActionsWrap' contains 'actionsWrap' as a substring, so the exit block is
# found from after the entry one rather than by a bare search that would match
# the wrong name and report a false order.
$exit_at = index $appends, 'actionsWrap', $entry_at + length 'entryActionsWrap'
  if $entry_at >= 0;
cmp_ok( $entry_at, '>=', 0, 'the entry block is one of them' );
cmp_ok( $exit_at,  '>=', 0, 'and the exit block is the other' );
cmp_ok( $entry_at, '<', $exit_at,
    'the entry block reaches the row first, so it renders above the exit one '
      . "- entry at $entry_at, exit at $exit_at, in: $appends" );

# --- each list says which it is ---------------------------------------------
#
# The entry label already names itself. What must change is the other one,
# which is currently the list you identify by its lack of a qualifier.

like( $js, qr/textContent\s*=\s*"Entry required actions"/,
    'the entry list names itself' );
like( $js, qr/textContent\s*=\s*"Exit required actions"/,
    'and the exit list names itself too, rather than being the unqualified one' );

# --- and each add field says which list it adds to ---------------------------
#
# Counted rather than denied. One placeholder string served both lists, so a
# fix that changed it in one place would leave the two still identical, and a
# denial of the old text would go green on that.

my $shared = () = $js =~ /"Add a required action\\u2026"/g;
is( $shared, 0,
    'no add field carries the placeholder that served both lists - '
      . "found $shared" );
like( $js, qr/Add an entry required action/,
    "the entry list's add field names its own list" );
like( $js, qr/Add an exit required action/,
    "and the exit list's add field names its own" );

# --- the fourth fault, the one that was in the picture and not the words -----

my @exit_rules  = $css =~ /(column-row__action-[a-z]+)/g;
my @entry_rules = $css =~ /(column-row__entry-action-[a-z]+)/g;
cmp_ok( scalar @exit_rules, '>', 0,
    'the stylesheet dresses the exit list - ' . scalar(@exit_rules)
      . ' rules mention it' );
cmp_ok( scalar @entry_rules, '>', 0,
    'and dresses the entry list as well, so its inputs stretch like the exit '
      . 'ones rather than sitting half width - '
      . scalar(@entry_rules) . ' rules mention it' );

# --- what must not change ----------------------------------------------------
#
# Green before this card and green after. The browser fixture finds both lists
# by these class names, and the collectors that build the save payload query
# the same two - so a reorder that renamed them would pass everything above
# and quietly stop saving one of the lists.

like( $js, qr/querySelectorAll\("\.column-row__action-input"\)/,
    'the exit list is still collected by the class the fixture drives' );
like( $js, qr/querySelectorAll\("\.column-row__entry-action-input"\)/,
    'and the entry list is still collected by its own' );

done_testing();

__END__

=head1 NAME

t/427-two-lists-that-read-as-one.t - the column editor must say which of its
two required-action lists is which

=head1 DESCRIPTION

TKT-591 gave a column a second required-action list - the one that gates entry
- and the editor rendered it below the existing list while leaving that list
labelled C<Required actions>. The owner met it for the first time and sent an
annotated screenshot back the same evening.

Four faults, three in his words and one in the picture: the entry list sits
below the exit list, which reverses the order a card meets them; the exit list
is identified only by lacking a qualifier; both add fields carry the same
placeholder; and the entry inputs render half width because the stylesheet has
rules for C<column-row__action-*> and none for C<column-row__entry-action-*>.

Read rather than driven. That is cheap here because TKT-703 moved this editor
out of a 12,203-byte C<q{}> string inside C<lib/Tira.pm> and into a file the
browser is served, hours before this card was picked up. The Playwright half of
the card is CHK-004 and belongs in the lab, where it can click.

The last two assertions are the ones that must not go red. The browser fixture
finds both lists by their input class names and the save collectors query the
same two, so a reorder that renamed them would satisfy every other assertion in
this file and quietly stop one of the lists from being saved.

=cut
