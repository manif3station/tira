#!/usr/bin/env perl
# TKT-746's third lift (TKT-832 was the second, TKT-830 the first): the human
# and table renderers - _markdown, _markdown_fields, _markdown_value and the
# HTML _dashboard_table - move out of lib/Tira.pm into lib/Tira/Render.pm,
# required lazily from format_output. Written RED, before the lift, so it
# fails against the pre-lift tree because lib/Tira/Render.pm does not exist.
#
# This is the Tira::Toon shape, not the Tira::Tasklist shape, and the
# difference was measured rather than assumed: all four subs are called only
# from format_output's own output-format branches, and nothing in t/, cli/ or
# the CLI modules names them. One caller means one require, not a forwarder
# per entry point.
#
# WHAT THIS FILE HAS TO PROVE, beyond "it still renders":
#
#   1. The module stands on its own - compiles without Tira.pm loaded first.
#   2. The laziness is real - asking for toon or json output never pulls
#      Tira::Render into %INC. This assertion is also what enforces the rule
#      against collapsing the require into a top-level use later.
#   3. The move changed nothing a caller can see. A lift is a move, so the
#      bytes out of human and table output must be identical, and the
#      failure modes (an unsupported format, table output handed data that
#      is not a board) must still refuse the same way.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';

# --- stands on its own -------------------------------------------------------

{
    my $out = qx{$^X -Ilib -e 'require Tira::Render; print "loaded\\n"' 2>&1};
    is( $?, 0, 'Tira::Render exits clean when required on its own' );
    like( $out, qr/loaded/, 'and it ran, without Tira.pm ever being loaded' );
}

require Tira;

# --- lazy: the formats that do not render never load it ---------------------

{
    my $tira = Tira->new;
    $tira->format_output( { a => 1 }, output => 'json' );
    ok( !exists $INC{'Tira/Render.pm'},
        'format_output(json) leaves Tira::Render out of %INC' );

    $tira->format_output( { a => 1 }, output => 'toon' );
    ok( !exists $INC{'Tira/Render.pm'},
        'and so does format_output(toon) - the other non-rendering branch' );
}

# --- and asking for human output loads it, right there ----------------------

{
    my $tira = Tira->new;
    $tira->format_output( { ref => 'R-1' }, output => 'human' );
    ok( exists $INC{'Tira/Render.pm'},
        'format_output(human) loads Tira::Render at the call site' );
}

# --- the lift changed location, not output ----------------------------------

{
    my $tira = Tira->new;

    my $human = $tira->format_output( { ref => 'R-1', title => 'A card' }, output => 'human' );

    # non-empty is the whole claim: a precondition for the assertion below,
    # which would pass just as well against an output that rendered nothing.
    like( $human, qr/\S/, 'human output has something in it' );
    like( $human, qr/R-1/, 'and names the record it was given' );

    # The narrowed form takes a different branch (_markdown_fields), and it
    # is the one TKT-157 fixed - asking for named fields must show those
    # fields rather than a hollow whole-card template.
    my $narrowed = $tira->format_output(
        { ref => 'R-2', title => 'Only this' }, output => 'human', fields => ['title'] );
    like( $narrowed, qr/title: Only this/, 'the narrowed human branch still prints the asked-for field' );
    unlike( $narrowed, qr/_None_/, 'and does not pad it out with empty placeholders' );
}

# --- the table branch, including how it refuses -----------------------------

{
    my $tira = Tira->new;

    my $table = $tira->format_output(
        {   _column_order => { ticket => ['backlog'] },
            ticket        => { backlog => [ { ref => 'T-1', title => 'Shown' } ] },
        },
        output => 'table',
    );
    like( $table, qr/T-1/, 'table output renders a card it was given' );
    like( $table, qr/</, 'and emits markup, which is what makes it the HTML builder' );

    # Escaping is done through _html_escape, which deliberately does NOT move
    # (the login page uses it too) - so this also proves the moved code still
    # reaches a helper left behind on Tira.
    my $escaped = $tira->format_output(
        {   _column_order => { ticket => ['backlog'] },
            ticket        => { backlog => [ { ref => 'T-2', title => 'a <script> tag' } ] },
        },
        output => 'table',
    );
    # Asserted as "the escaped form is present", NOT as "the string <script>
    # is absent". The first version of this line was the second, and it failed
    # for the wrong reason: the dashboard page carries its own <script> block
    # of JavaScript, so the absence test could never pass and said nothing
    # about escaping either way. The claim is about what happened to the
    # title, so the assertion has to name the title.
    like( $escaped, qr/a &lt;script&gt; tag/,
        'a title carrying markup is escaped, via the helper that stayed on Tira' );
    unlike( $escaped, qr/card__title"><script>/,
        'and the raw markup is not injected into the card title' );

    eval { $tira->format_output( { not => 'a board' }, output => 'table' ) };
    like( $@, qr/Table output requires dashboard data/,
        'table output still refuses data that is not a board' );

    eval { $tira->format_output( {}, output => 'xml' ) };
    like( $@, qr/Unsupported output format/,
        'and an unknown format is still refused by format_output itself' );
}

# --- a dashboard rendered as human, not as a table --------------------------
#
# _markdown has a branch for dashboard-shaped data (anything carrying
# _column_order) that renders it as markdown headings rather than falling
# through to the JSON dump - and nothing reached it. Every existing test that
# builds dashboard data asks for it as -o table. It read as covered while the
# sub lived in lib/Tira.pm because four uncovered statements in 14,419 lines
# round to 100.0%; the lift shrank the denominator and it appeared, the third
# time in three lifts that has happened.
#
# Both sides of the empty/non-empty ternary are asserted, because a column
# list that never renders a card and one that never renders _Empty._ are both
# wrong and neither is caught by testing only the other.

{
    my $tira = Tira->new;
    my $human = $tira->format_output(
        {   _column_order => { ticket => [ 'backlog', 'done' ] },
            ticket        => {
                backlog => [ { ref => 'T-1', title => 'Has a title' }, { ref => 'T-2' } ],
                done    => [],
            },
        },
        output => 'human',
    );

    like( $human, qr/^# Tira Dashboard/m, 'dashboard data asked for as human renders as a dashboard, not a JSON dump' );
    like( $human, qr/^## TICKET/m,        'with the board type as a heading' );
    like( $human, qr/^### backlog/m,      'and each column under it' );
    like( $human, qr/`T-1` Has a title/,  'a card with a title shows its title' );
    like( $human, qr/`T-2`/,              'and a card without one still shows its reference' );
    unlike( $human, qr/`T-2` \S/,         'without inventing a title for it' );
    like( $human, qr/### done\n\n?_Empty\._/, 'an empty column says so rather than rendering nothing' );
}

done_testing();

__END__

=head1 NAME

t/485-a-renderer-that-waits-to-be-asked.t - Tira::Render loads standalone, and only on request

=head1 DESCRIPTION

TKT-834, the third lift under TKT-746. Proves the two properties that make a
lift real - the module compiles standalone without C<Tira.pm> loaded first,
and a C<format_output> call that does not render leaves it out of C<%INC> -
and that the move changed nothing a caller can see, across both rendering
branches and both of their refusals.

The C<%INC> assertion is also the guard against a later change collapsing the
per-call C<require> into a top-level C<use>, which would restore the compile
cost the lift removed while leaving every behavioural test passing.

=cut
