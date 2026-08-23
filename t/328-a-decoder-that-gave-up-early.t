#!/usr/bin/env perl
# The decoder half of TKT-386. The encoder now writes a map nested inside a
# list item correctly, but Data::TOON::Decoder could not read that shape back
# even once it was written correctly - not the encoder's fault at all,
# established here by decoding well-formed input the (fixed) encoder itself
# produces.
#
# The wrong branch is in Data::TOON::Decoder::_decode_array_value's list-item
# loop. It checks whether the FIRST key on a "- key: value" line has an empty
# value (meaning a nested map) and correctly recurses into _decode_object for
# it - but every key AFTER the first is parsed by a second loop that calls
# _parse_primitive on whatever follows the colon unconditionally. An empty
# value there (a nested map's own key line, not a primitive) becomes the
# empty string, and the map's own indented lines are then seen one depth
# deeper than the loop expects and stop it outright - so the sibling key
# after the nested map is lost too, not merely mis-parsed.
#
# _decode_object (in the same module) already has the right rule for this -
# empty after the colon means recurse - and this override gives the
# array-item loop the same rule, reimplemented rather than delegated because
# the flaw is inside the loop being overridden, not somewhere else to hand
# off to.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Tira;

my $shape = { rows => [ { id => 'R-1', nested => { when => 'T1', who => 'inner' }, who => 'outer' } ] };

# --- the round trip, through Tira's own (now-fixed) encoder --------------------------

{
    my $encoded = Tira->new->format_output($shape);
    my $decoded = Data::TOON->decode($encoded);
    is_deeply( $decoded, $shape, 'a map nested in a list item survives encode then decode' )
      or diag($encoded);
}

# --- the two failures named in the ticket, read individually -------------------------

{
    my $encoded = Tira->new->format_output($shape);
    my $decoded = Data::TOON->decode($encoded);
    is_deeply( $decoded->{rows}[0]{nested}, { when => 'T1', who => 'inner' },
        'the nested map comes back as a map, not an empty string' );
    is( $decoded->{rows}[0]{who}, 'outer',
        "and the sibling key after it survives too - not lost outright" );
}

# --- a nested map as the very first key still works (the branch this did not touch) --

{
    my $first_key_shape = { rows => [ { nested => { a => 1 }, id => 'R-1' } ] };
    my $encoded = Tira->new->format_output($first_key_shape);
    my $decoded = Data::TOON->decode($encoded);
    is_deeply( $decoded, $first_key_shape,
        'a nested map as the item\'s first key - already handled - is unaffected' );
}

# --- two nested maps in the same item, one after the other ---------------------------

{
    my $two_maps = { rows => [ { id => 'R-1', a => { x => 1 }, b => { y => 2 } } ] };
    my $encoded = Tira->new->format_output($two_maps);
    my $decoded = Data::TOON->decode($encoded);
    is_deeply( $decoded, $two_maps, 'two nested maps in the same item both survive, in order' )
      or diag($encoded);
}

# --- proved by putting the module's own branch back -----------------------------------
#
# Every assertion above is a round trip, and a round-trip assertion can pass
# by accident if the encoded text never exercised the broken shape at all.
# Disabled here so the drop must come back.

{
    my $encoded = Tira->new->format_output($shape);

    no warnings 'redefine';
    local *Data::TOON::Decoder::_decode_array_value = $Tira::TOON_ARRAY_DECODE_BEFORE;

    my $broken = Data::TOON->decode($encoded);
    isnt( $broken->{rows}[0]{nested}, $shape->{rows}[0]{nested},
        'the override is what makes the difference' );
    ok( !exists $broken->{rows}[0]{who} || $broken->{rows}[0]{who} ne 'outer',
        'and without it, the sibling key after the nested map is dropped, matching the ticket' )
      or diag( explain($broken) );
}

done_testing;

__END__

=head1 NAME

328-a-decoder-that-gave-up-early.t - Data::TOON::Decoder reads a map nested in a list item

=head1 DESCRIPTION

C<Data::TOON::Decoder>'s list-item parsing only recursed into a nested map
when it was the FIRST key of a "- key: value" item; every later key was
parsed as a primitive unconditionally, so an empty value there (a nested
map's own key line) became the empty string and the loop then stopped at
the nested map's own indented lines, dropping every field after it too.
Tira now overrides C<_decode_array_value> to give it the same
empty-means-nested-object rule C<_decode_object> already has, for every
key in a list item, not just the first. TKT-393.

=cut
