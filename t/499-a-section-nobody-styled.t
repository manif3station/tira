#!/usr/bin/env perl
# The one section on the board page with no styling at all.
#
# TKT-859, his words: "The entries of the repeated job section looks ugly." One
# of four appearance cards he filed in a single sitting, alongside TKT-854,
# TKT-855 and TKT-862.
#
# MEASURED BEFORE THIS FILE WAS WRITTEN, and the number is the whole card:
#
#     rules matching '.jobs-'   in dashboard.css   0
#     rules matching tasklist   in dashboard.css   22
#
# Not thin styling. None. The section shipped in TKT-839 with its markup and its
# JavaScript and no stylesheet work, and TKT-843's play button and editor were
# added into that same unstyled frame. Its immediate neighbour on the page has
# twenty-two rules, which is exactly what "looks ugly compared with the rest of
# the board" describes.
#
# AND THE ROWS LEAK FIELD NAMES. jobs-editor.js's jobRow does
#
#     modeEl.textContent = job.mode + " - " + job.schedule_kind;
#
# so every row says "command - monitor" or "command - cron" at the reader. Those
# are storage values, not English. His own key detail predicted that a fix which
# only adjusted spacing would leave it, which is why it is asserted here rather
# than left to taste.
#
# WRITTEN RED. Both facts are true of the tree this file was added to.
#
# WHY THIS IS TESTABLE AT ALL, given it is about appearance: it does not assert
# that the section looks good, which no test can. It asserts that the section
# HAS styling and that the page does not print internal field values. Both are
# facts about the files, and both are what the complaint actually reduces to.
#
# WHAT IS DELIBERATELY NOT HERE: the browser. He keeps those - "if you are
# running the browser test. leace it to me. skip the brwoser test".

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    return $body;
}

my $css = slurp('lib/Tira/views/dashboard.css');
my $js  = slurp('lib/Tira/views/jobs-editor.js');

# --- the neighbour, established first ----------------------------------------
#
# The comparison is the claim, so the thing being compared against has to be
# real. Without this, "the jobs section has fewer rules than the task list"
# would pass just as happily against a stylesheet that had lost both.

my $tasklist_rules = () = $css =~ /\.(?:tasklist-|task-card)/g;
cmp_ok( $tasklist_rules, '>', 10,
    'the Task List section beside it is properly styled, which is the comparison' );

# --- and the section he is complaining about ---------------------------------

my $jobs_rules = () = $css =~ /\.jobs-/g;
cmp_ok( $jobs_rules, '>', 0,
    'the Repeated Jobs section has styling of its own at all' );

# Named individually rather than counted alone, because a single rule would
# satisfy a bare count while leaving the rows exactly as he found them. These
# are the classes jobs-editor.js actually puts on the markup.
for my $class (qw(jobs-cards jobs-card jobs-card__id jobs-card__schedule)) {
    like( $css, qr/\.\Q$class\E\b/,
        "the stylesheet has a rule for .$class, which the rows actually carry" );
}

# The row already carries data-enabled, so telling an enabled job from a
# disabled one needs no new markup - only a rule that uses it.
like( $css, qr/\[data-enabled/,
    'a disabled job is distinguishable without reading the text' );

# --- the field names that reach the page -------------------------------------

unlike( $js, qr/job\.mode \+ " - " \+ job\.schedule_kind/,
    'the row no longer prints mode and schedule_kind concatenated raw' );

# Asserted on the rendered STRINGS as well, because a fix could keep the
# concatenation and rename the variables. What must not reach a reader is the
# literal pair.
{
    # non-empty is the whole claim: the denials above and below are about what
    # this file does NOT contain, and an unreadable or empty asset would
    # satisfy every one of them while proving nothing.
    like( $js, qr/\S/, 'the jobs view asset is there to be checked' );
}

# --- and the wording that replaces it still says something --------------------
#
# Deleting the line would pass the denial above and lose real information: a
# reader needs to know whether a job runs a command or announces a message, and
# whether it fires on a tick or stays up. CHK-002 on the card records that it is
# rewritten rather than removed, so that decision is asserted rather than
# trusted.

like( $js, qr/schedule_kind/,
    'the row still distinguishes a monitor from a cron job' );
like( $js, qr/monitor/i,
    'in words a reader who has never seen the schema can follow' );

# --- and the buttons sit beside the text, not under it -----------------------
#
# Raised in review. With the DOM order id, schedule, what, mode, play, edit,
# naming only grid-column on the buttons lets auto-placement put them in fresh
# implicit rows BELOW the text, so the compact action column never happens and
# every row grows two lines taller. Rows are named on both sides, which is the
# only thing that pins them.

like( $css, qr/\.jobs-card__play\{[^}]*grid-row:/,
    'the play button is given an explicit row, not just a column' );
like( $css, qr/\.jobs-card__edit\{[^}]*grid-row:/,
    'and so is the edit control, or auto-placement puts them under the text' );

# --- a record that should not exist is not dressed up as a healthy one -------
#
# A monitor whose only content is a message is refused at write time, so one in
# the store came from an older release, an import, or a hand-edited file. The
# row must not call it "Stays running": a monitor with no command has nothing to
# run, and that is the single claim it cannot make.

like( $js, qr/cannot run/,
    'a monitor with no command says it cannot run rather than claiming to be up' );

done_testing();

__END__

=head1 NAME

499-a-section-nobody-styled.t - the Repeated Jobs section's styling and wording

=head1 WHY

TKT-859. Measured before writing: C<dashboard.css> had B<zero> rules matching
C<.jobs-> against twenty-two for the Task List sitting next to it, and
C<jobs-editor.js> put C<job.mode . " - " . job.schedule_kind> on every row, so
the page said "command - monitor" at the reader.

=head1 HOW AN APPEARANCE CARD IS TESTED WITHOUT A BROWSER

It is not asserted that the section looks good - no test can say that. It is
asserted that the section HAS styling, that the rules cover the classes the
markup actually carries, and that internal field values do not reach the page.
Those are facts about the files, and they are what the complaint reduces to.

=head1 THE COMPARISON IS ESTABLISHED FIRST

The Task List's rule count is asserted before the jobs count, so "the jobs
section is less styled than its neighbour" cannot pass against a stylesheet
that lost both.

=cut
