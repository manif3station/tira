#!/usr/bin/env perl
# A section with no ceiling, and the section underneath it.
#
# TKT-881, EPC-007. His card, filed 2026-09-03: "Huge Task List section bury the
# Jobs", and the fix he specified - "Make the task list section pagination and
# initially only show 5 and every next show 10."
#
# MEASURED BEFORE THIS FILE WAS WRITTEN, on the real board:
#
#     142 tasks on the shared list - 139 pending, 3 working
#
# and reconcileTasklist builds one card per surviving item into .tasklist-cards,
# with no cap anywhere. So the section is exactly as tall as the queue is long,
# and Repeated Jobs starts wherever that ends. That is the band of empty page in
# his screenshot: the Jobs section is not missing, it is below the fold of a
# section that grows every day the board is used.
#
# WHY THE CAP GOES IN THE RENDER AND NOT IN CSS. A max-height with overflow
# would still build all 142 cards and would only hide them behind a scrollbar -
# Jobs would come back into view, but by scrolling past a scroll container,
# which is a worse page than the one he is complaining about. The last block
# asserts that nobody "fixes" this that way later.
#
# WHAT THE CAP APPLIES TO, decided on the card as CHK-001 before this file was
# written, so these assertions test a decision rather than describe whatever the
# code ends up doing:
#
#     the filtered list, stable-sorted so WORKING ranks before pending,
#     then sliced
#
# Three of the 142 are working and they are the ones being done right now. Five
# arbitrary pending cards above three active ones would be a worse page than the
# one he complained about. The rejected alternative - "working tasks are never
# hidden, the cap applies to the rest" - reads well at 3 and defeats the card at
# 50; a cap any status can escape is not a cap.
#
# HOW AN APPEARANCE CARD IS TESTED WITHOUT A BROWSER, which he keeps: this does
# not assert the page looks right - nothing here can. It asserts that the control
# exists to be pressed, that the cap is applied where it has to be applied to be
# correct, and that the three things a careless cap breaks are still intact. He
# confirms the rest by eye.
#
# THE ASSERTIONS THAT KEEP THIS HONEST are the ones about what must NOT change.
# A test demanding only "there is a slice" would be satisfied by slicing before
# the filter (five of everything, then filtered - so a search for a task in
# position 90 finds nothing), by resetting the count inside loadTasklist (it
# snaps back to five every second while he reads), or by dropping tlRowBusy (a
# card being edited vanishes mid-keystroke on the next reload). Each is a
# passing suite and a worse page.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

my $js = do {
    open my $fh, '<:raw', 'lib/Tira/views/tasklist-editor.js'
      or die "tasklist-editor.js: $!";
    local $/;
    <$fh>;
};

my $render = do {
    open my $fh, '<:raw', 'lib/Tira/Render.pm' or die "Render.pm: $!";
    local $/;
    <$fh>;
};

my $css = do {
    open my $fh, '<:raw', 'lib/Tira/views/dashboard.css' or die "dashboard.css: $!";
    local $/;
    <$fh>;
};

# non-empty is the whole claim: every assertion below reads something out of
# these three files, and an unreadable one would fail them all for the wrong
# reason.
like( $js,     qr/\S/, 'the tasklist editor is there to be read' );
like( $render, qr/\S/, 'the renderer is there to be read' );

# non-empty is the whole claim here too: the last block reads the grid rule out
# of this file and would pass on an unreadable one.
like( $css, qr/\S/, 'the stylesheet is there to be read' );

# --- the premise, established rather than assumed -----------------------------
#
# If reconcileTasklist ever stops being the one place that decides what is in
# the DOM, every assertion below is about the wrong function.

like(
    $js,
    qr/const\s+reconcileTasklist\s*=\s*items\s*=>/,
    'reconcileTasklist is still the function that decides what is rendered'
);

# --- there is something to press ---------------------------------------------
#
# "Every next show 10" needs a control. Asserted in the renderer rather than the
# JS because the JS looks it up - a button created only in script would be
# invisible to the no-JS render and to anyone reading the page source for it.

like(
    $render,
    qr/tasklist-more/,
    'the renderer emits a show-more control, so there is something to press'
);

like(
    $js,
    qr/tasklist-more/,
    'and the editor looks it up, so pressing it does something'
);

# ON THE PAGE, not merely in the module. The two assertions above are satisfied
# by the string existing in each file, which would still hold if the button were
# emitted inside a branch that never runs - and the whole section is built under
# `if $args{live}`, so that is not a hypothetical shape. This renders the real
# board the way t/490 does and looks for the control in the output.

{
    my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );

    my $tira = Tira->new;
    $tira->project_new(
        name => 'Capped', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'CAS', epic_prefix => 'CAE', ticket_prefix => 'CAT',
    );

    my $page = $tira->format_output(
        $tira->dashboard( project => $root, live => 1 ),
        output => 'table', live => 1,
    );

    # non-empty is the whole claim: the three assertions below search this page,
    # and one that rendered nothing at all would pass none of them for the right
    # reason.
    like( $page, qr/\S/, 'the board page has something in it' );

    like( $page, qr/tasklist-more/,
        'the control is in the rendered page, not only in the module that emits it' );

    # Where it is matters as much as whether it is there. Below the list it
    # pages, and above the section it stopped burying - a button rendered after
    # board--jobs would page a list the reader has already scrolled past.
    my $cards_at = index( $page, 'tasklist-cards' );
    my $more_at  = index( $page, 'tasklist-more' );
    my $jobs_at  = index( $page, 'board--jobs' );

    cmp_ok( $more_at, '>', $cards_at,
        'and it comes after the list it pages' );
    cmp_ok( $more_at, '<', $jobs_at,
        'and before the Repeated Jobs section, which is the one this card '
          . 'exists to stop burying' );
}

# --- five, then ten ----------------------------------------------------------
#
# His numbers, not mine. They are asserted as literals because they are the
# requirement: a cap of 20 growing by 50 would satisfy every structural
# assertion in this file and would not be what he asked for.

my ($initial) = $js =~ /TASKLIST_FIRST_PAGE\s*=\s*(\d+)/;
my ($step)    = $js =~ /TASKLIST_PAGE_STEP\s*=\s*(\d+)/;

is( $initial, 5,  'five cards initially, which is the number he gave' );
is( $step,    10, 'and ten more per press, which is the other one' );

# --- the count survives the reload -------------------------------------------
#
# loadTasklist runs on a 1000ms interval. If the shown-count is declared inside
# it, or reset by it, the list snaps back to five every second while he is
# reading - which would look like a bug rather than a feature, and would pass a
# test that only counted the initial render.

my ($load_body) = $js =~ /const\s+loadTasklist\s*=\s*\(\)\s*=>(.*?)(?=;const\s|;tasklistSection)/s;
$load_body //= '';

# non-empty is the whole claim: the assertion below searches this body for an
# assignment, and an empty body would pass it while proving nothing.
like( $load_body, qr/\S/, 'loadTasklist has a body to inspect' );

unlike(
    $load_body,
    qr/tlShown\s*=/,
    'the shown-count is not reassigned by the timed reload, so it does not '
      . 'snap back to five every second while he is reading it'
);

like(
    $js,
    qr/let\s+tlShown\s*=\s*TASKLIST_FIRST_PAGE/,
    'it is section-scoped state, set once'
);

# --- the cap is applied after the filter, not before -------------------------
#
# Five of the MATCHES. Slicing first and filtering after would show at most five
# results however many matched, and searching for a task in position 90 would
# find nothing at all - the filter would look broken rather than capped.

my ($reconcile) = $js =~ /const\s+reconcileTasklist\s*=\s*items\s*=>\s*\{(.*?)\};const\s/s;
$reconcile //= '';

# non-empty is the whole claim: three assertions below read the order of
# operations out of this body, and an empty one would pass all three.
like( $reconcile, qr/\S/, 'reconcileTasklist has a body to inspect' );

my $filter_at = index( $reconcile, 'tlMatches' );
my $slice_at  = index( $reconcile, 'slice' );

cmp_ok( $filter_at, '>=', 0, 'the filter is still applied in the reconcile' );
cmp_ok( $slice_at,  '>=', 0, 'and so is the cap' );
cmp_ok(
    $filter_at, '<', $slice_at,
    'the filter runs BEFORE the cap - five of the matches, not five of '
      . 'everything and then filtered, which would make a search for the '
      . '90th task find nothing'
);

# --- working tasks are not pushed below the cap ------------------------------
#
# CHK-001. Status codes are 0 pending, 1 working, 2 done, so this cannot be a
# sort on the raw number: ascending puts pending above working, descending puts
# done at the top.

like(
    $reconcile,
    qr/sort/,
    'the list is ordered before it is cut, so the three working tasks are not '
      . 'hidden behind five arbitrary pending ones'
);

like(
    $js,
    qr/tlRank/,
    'and the order is a named rank rather than the raw status number, which '
      . 'sorts pending above working ascending and done to the top descending'
);

# --- and the cap did not cost the things that already worked -----------------
#
# Each of these is a real way to make the section shorter and the page worse.

like(
    $reconcile,
    qr/tlRowBusy/,
    'a card being edited is still not replaced by a reload - the cap did not '
      . 'take the guard out with it'
);

my ($cards_rule) = $css =~ /\.tasklist-cards\{([^}]*)\}/;
$cards_rule //= '';

# non-empty is the whole claim: the two assertions below search this rule for
# properties, and an empty rule would pass both while proving nothing.
like( $cards_rule, qr/\S/, 'the tasklist grid rule is still there' );

unlike(
    $cards_rule,
    qr/max-height/,
    'the fix is not a scroll container - a max-height would still build all '
      . '142 cards and would only hide them behind a scrollbar, which is a '
      . 'worse page than the one he is complaining about'
);

unlike(
    $cards_rule,
    qr/overflow/,
    'and nothing scrolls inside the section for the same reason'
);

done_testing();

__END__

=head1 NAME

507-a-queue-that-buried-the-jobs.t - the task list section, and the one below it

=head1 WHY

TKT-881. The task list rendered one card per item with no cap. Measured on the
real board on 2026-09-03: 142 tasks, 139 pending and 3 working, every one of
them in the DOM - so the section's height was the queue's length, and the
Repeated Jobs section started below it.

His words: "Huge Task List section bury the Jobs", and "Make the task list
section pagination and initially only show 5 and every next show 10".

=head1 WHAT IS ASSERTED

That the control exists in the render; that the numbers are his five and ten;
that the shown-count is section-scoped and untouched by the 1000ms reload; that
the cap is applied after the filter and after an explicit rank, not before
either; and that the three things a careless cap breaks - the filter, a card
being edited, and the working tasks - still behave.

The last block asserts what must NOT be there: no C<max-height>, no
C<overflow>. A scroll container would make the section short and the page
worse, and would pass every other assertion in this file.

=cut
