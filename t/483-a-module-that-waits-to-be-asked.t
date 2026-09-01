#!/usr/bin/env perl
# TKT-746's first lift: the TOON encoder/decoder overrides moved out of
# Tira.pm into Tira::Toon, required at the call site inside format_output's
# 'toon' branch rather than at the top of the engine. Two things a lift like
# that has to prove, or it is a rename wearing "lazy" as a label:
#
#   1. The module stands on its own - it compiles and applies its patches
#      without Tira.pm having been loaded first. This is what t/431 already
#      asserts by name-resolution for the CLI submodules; it does not run
#      anything standalone, so it would not have caught a Tira::Toon that
#      only worked as a side effect of being loaded after Tira.pm's own
#      Data::TOON::Encoder/::Decoder use lines. There are none left to fall
#      back on - this file is the thing that actually loads it alone.
#
#   2. The laziness is real - a command that never asks for toon output
#      never pulls Tira::Toon into %INC. Requiring it unconditionally at the
#      top of Tira.pm would pass every other test in the suite and still be
#      exactly the defect TKT-746 was filed to remove.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';

# --- stands on its own -------------------------------------------------------

{
    my $out = qx{$^X -Ilib -e 'require Tira::Toon; print "loaded\\n"' 2>&1};
    is( $?, 0, 'Tira::Toon exits clean when required on its own' );
    like( $out, qr/loaded/, 'and it ran, without Tira.pm ever being loaded' );
}

# --- the patches actually took, standalone -----------------------------------

{
    my $out = qx{$^X -Ilib -MData::TOON -e '
        require Tira::Toon;
        print Data::TOON->encode({ v => "2.20" });
    ' 2>&1};
    like( $out, qr/"2\.20"/, 'the numeric-string quoting fix applies standalone too' );
}

# --- lazy: a call that does not ask for toon does not load it ---------------

require Tira;

{
    my $tira = Tira->new;
    $tira->format_output( { a => 1 }, output => 'json' );
    ok( !exists $INC{'Tira/Toon.pm'},
        'format_output(json) leaves Tira::Toon out of %INC' );

    $tira->format_output( { a => 1 }, output => 'human' );
    ok( !exists $INC{'Tira/Toon.pm'},
        'format_output(human) leaves Tira::Toon out of %INC' );
}

# --- and asking for toon loads it, right there ------------------------------

{
    my $tira = Tira->new;
    $tira->format_output( { a => 1 }, output => 'toon' );
    ok( exists $INC{'Tira/Toon.pm'},
        'format_output(toon) loads Tira::Toon at the call site' );
}

# --- a bulleted list item that is not "key: value" -------------------------
#
# The override's list-item loop handles two shapes: "- key: value" (a map)
# and a bare "- value" (a primitive, not something Tira's own encoder ever
# writes since it does not mix scalar and map items in one array, but valid
# TOON text the decoder still has to read). Exercised directly rather than
# through format_output, the way t/328 already tests this decoder's other
# branches without going through the encoder for shapes the encoder does not
# produce.

{
    require Tira::Toon;
    my $decoded = Data::TOON->decode("tags[2]:\n  - a\n  - id: R-1\n");
    is_deeply( $decoded, { tags => [ 'a', { id => 'R-1' } ] },
        'a bare scalar item in a bulleted list decodes as a primitive, not a dropped line' );
}

# --- an empty map as a list item, on the encode side ------------------------
#
# _encode_object_with_array's per-item loop takes the "no keys" branch only
# for an item with zero fields - untested by every other TOON test in the
# suite, all of which encode items that carry at least one field.

{
    my $out = Tira->new->format_output( { rows => [ {}, { id => 'R-1', nested => { a => 1 } } ] } );
    like( $out, qr/rows\[2\]:\n  -\n  - id:/, 'an empty map in the list renders as a bare dash, not dropped' );
}

# --- blank lines inside a bulleted array, on the decode side ---------------
#
# Three places in the decoder's list-item loop skip a blank line and keep
# going: the lookahead peek that decides list-vs-inline format, the loop that
# walks each item, and the loop that walks a map item's sibling keys. Tira's
# own encoder never writes a blank line inside an array, so nothing round-
# tripped through format_output reaches any of the three - each is
# constructed by hand instead, the way t/328 already does for shapes the
# encoder does not produce.

{
    my $decoded = Data::TOON->decode("tags[2]:\n\n  - id: R-1\n  - id: R-2\n");
    is_deeply( $decoded, { tags => [ { id => 'R-1' }, { id => 'R-2' } ] },
        'a blank line before the first bulleted item is skipped during the format-lookahead' );
}

{
    my $decoded = Data::TOON->decode("tags[2]:\n  - id: R-1\n\n  - id: R-2\n");
    is_deeply( $decoded, { tags => [ { id => 'R-1' }, { id => 'R-2' } ] },
        'a blank line between two bulleted items is skipped' );
}

{
    my $decoded = Data::TOON->decode("tags[1]:\n  - id: R-1\n\n    name: hello\n");
    is_deeply( $decoded, { tags => [ { id => 'R-1', name => 'hello' } ] },
        'a blank line between a map item\'s sibling keys is skipped' );
}

# --- the lift changed location, not behaviour --------------------------------

{
    my $tmp  = tempdir( CLEANUP => 1 );
    my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, 'board' );
    $tira->project_new(
        name => 'Lifted', dir => $root, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'LFS', epic_prefix => 'LFE', ticket_prefix => 'LFT',
    );
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Still reads back as itself after the lift' );
    $tira->record_update( author => 'claude', project => $root, ref => $card->{ref}, fix_version => '2.20' );
    my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
    my $toon  = $tira->format_output( $shown, output => 'toon' );
    like( $toon, qr/fix_version:\s*"2\.20"/,
        'a numeric-looking string still round-trips correctly after the lift' );
}

done_testing();

__END__

=head1 NAME

t/483-a-module-that-waits-to-be-asked.t - Tira::Toon loads standalone, and only on request

=head1 DESCRIPTION

TKT-746 lifted the TOON encoder/decoder overrides out of C<lib/Tira.pm> into
C<lib/Tira/Toon.pm>, required from C<format_output>'s C<toon> branch rather
than C<use>d at the top of the engine. This file proves the two things that
make that a real lift rather than a rename: the module compiles and applies
its patches on its own, without C<Tira.pm> having been loaded first, and a
C<format_output> call that does not ask for C<toon> output never pulls it
into C<%INC>.

=cut
