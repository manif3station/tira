#!/usr/bin/env perl
# TKT-793. The column editor renders two required-action lists (exit, then
# entry) but TKT-678 added a third column-level list - administrative_actions
# - with the identical shape and the identical column_apply round-trip
# support underneath. The dialog had no rendering, no input row, and no
# save-path for it at all: a board managed through the browser dashboard
# could never see, set, or clear an administrative-action exemption.
#
# Read rather than driven, the same way t/427 reads this editor: the file
# left lib/Tira.pm for lib/Tira/views/column-editor.js under TKT-703, so a
# test can open the file the browser is served without a lab. The Playwright
# half belongs in the lab per t/427's own precedent.

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

ok( $js,  'the column editor was read - ' . length($js) . ' bytes' );
ok( $css, 'the stylesheet was read - ' . length($css) . ' bytes' );

# --- the third list renders, labeled, alongside the other two ---------------

like( $js, qr/textContent\s*=\s*"Administrative actions"/,
    'the administrative-actions list names itself' );
like( $js, qr/Add an administrative action/,
    "the administrative list's add field names its own list, not a shared "
      . 'placeholder' );

# --- it reaches the row, the same way the other two do ----------------------

my ($appends) = join ' ', $js =~ /row\.append\(([^)]*)\)/g;
like( $appends, qr/administrativeActionsWrap/,
    'the administrative-actions block is appended to the row - ' . $appends );

# --- it is collected into the save payload, by its own class ----------------
#
# t/427's own warning: a rename that satisfies every other assertion here
# would still quietly stop this list from saving if the collector query
# changed. Asserted directly against the class the fixture would drive.

like( $js, qr/querySelectorAll\("\.column-row__administrative-action-input"\)/,
    'the administrative list is collected by its own class' );
like( $js, qr/entry\.administrative_actions\s*=/,
    'a non-empty administrative list is written onto the save payload as '
      . 'administrative_actions' );

# --- clearing every item still saves an empty list, not a dropped field -----
#
# The other two lists guard this the same way: a dataset flag set at render
# time if the column arrived with a non-empty list, read back at save time so
# "everything removed" and "never had any" are told apart.

like( $js, qr/hadAdministrativeActions/,
    'a column that arrived with administrative actions is flagged so '
      . 'clearing every one still saves an empty list rather than omitting '
      . 'the field' );

# --- it does not render half width, the fault the entry list once had -------
#
# TKT-591's own history: the entry list rendered half width because the
# stylesheet had rules for column-row__action-* and none for
# column-row__entry-action-*. The administrative list needs the same rules
# the other two already have, not a fresh half-width regression of its own.

my @admin_rules = $css =~ /(column-row__administrative-action-[a-z]+)/g;
cmp_ok( scalar @admin_rules, '>', 0,
    'the stylesheet dresses the administrative list too, so its inputs '
      . 'stretch like the other two rather than sitting half width - '
      . scalar(@admin_rules) . ' rules mention it' );
like( $css, qr/\.column-row__administrative-action-add:hover/,
    "the administrative list's add button gets the same hover treatment "
      . 'the other two already have' );
like( $css, qr/\.column-row__administrative-action-remove:hover/,
    "and its remove button does too" );

done_testing();

__END__

=head1 NAME

t/465-a-third-list-nobody-could-reach.t - the column editor's Columns dialog
gains a UI surface for administrative_actions, its third required-action-
shaped list

=head1 DESCRIPTION

TKT-678 added administrative_actions to the engine (column_apply,
C<tira.column.update --administrative-action>) with the identical shape and
round-trip support as the existing required_actions/entry_required_actions
lists - but the browser dashboard's Columns dialog never gained a fourth UI
block for it. A board managed primarily through the browser could never see,
set, or clear an administrative-action exemption; the capability existed
only via CLI. TKT-793.

C<buildActionRow()>, the shared row-builder already used by the exit and
entry lists, is generalized from an C<isEntry> boolean into a three-way
C<kind> ('exit'|'entry'|'administrative') so the same helper builds all
three lists' rows, add buttons, remove buttons, and placeholders. A third
UI block (C<administrativeActionsWrap>) is appended to each column row, and
C<columnLayout()> - the save-path - reads it back into the C</columns/apply>
payload as C<administrative_actions>, using the same "flag a non-empty list
at render time" trick the other two already use so clearing every item still
saves an empty list rather than dropping the field. New stylesheet rules
mirror the entry list's, so the administrative inputs do not repeat TKT-591's
half-width regression.

Read rather than driven, the same way t/427 reads this editor - cheap since
TKT-703 already moved it into its own file. The Playwright half belongs in
the lab, per t/427's own precedent.

=cut
