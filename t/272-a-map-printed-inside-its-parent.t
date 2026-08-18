#!/usr/bin/env perl
# A map inside a list item is printed inside it.
#
# TOON is the default output and its audience is agents. A map nested inside a
# list element was rendered flattened into its parent: the inner map's first key
# landed on the parent key's line and the rest at the parent's own indent, so
# questions[].answer printed 'author' twice and 'text' twice at one level, with
# nothing marking where the answer ended.
#
# What that cost, measured on a real reader rather than imagined. zen-framework
# filed two bug reports saying tira.question.mark stores nothing, citing "0 marks
# across the whole board". The mark was stored the whole time, at answer.mark.
# They had read the flattened output, seen no mark among what looked like the
# question's own keys, and applied one bad predicate to 89 questions. They
# retracted it themselves; their board-wide recount was 86 of 89 marked.
#
# The wrong line is in Data::TOON::Encoder::_encode_object_with_array:
#
#     my $first_val = $self->_encode_value($obj->{$first_key});
#     push @lines, $item_indent . "- $first_key: $first_val";
#
# It interpolates a rendered value after "$key: ", which assumes one line.
#
# The override delegates to the module for every shape it renders correctly and
# takes over only for a list item that has a map among its values. That
# narrowness is asserted here too, because the first draft of the fix widened it
# and turned the compact "tags[2]: a,b" into a dash list nobody asked for.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Tira;

# --- the shape that was broken ------------------------------------------------------

sub lines_of { return [ split /\n/, Tira->new->format_output( $_[0] ) ] }

sub indent_of {
    my ($line) = @_;
    my ($lead) = $line =~ /\A(\s*)/;
    return length $lead;
}

sub line_with {
    my ( $lines, $pattern ) = @_;
    my ($found) = grep { $_ =~ $pattern } @{$lines};
    return $found;
}

{
    my $lines = lines_of(
        {   questions => [
                {   answer => { author => 'michael', mark => 'ok', text => 'yes' },
                    author => 'claude',
                    id     => 'Q-1',
                    text   => 'is it stored?',
                },
            ],
        }
    );

    my $answer_author   = line_with( $lines, qr/author:\s*michael/ );
    my $question_author = line_with( $lines, qr/author:\s*claude/ );
    ok( defined $answer_author,   'the answer has an author line' );
    ok( defined $question_author, 'and so does the question' );

    cmp_ok( indent_of($answer_author), '>', indent_of($question_author),
        "the answer's keys are printed deeper than the question's own" );

    my $mark = line_with( $lines, qr/mark:\s*ok/ );
    ok( defined $mark, 'the mark is printed' );
    cmp_ok( indent_of($mark), '>', indent_of($question_author),
        'and it is visibly inside the answer, which is the whole complaint' );
}

# --- no two keys of different maps at one indent -------------------------------------
#
# The generalisation of the above, and the thing a reader actually trips over: it
# is not that the mark is missing, it is that nothing says which map it belongs
# to. Asserted by name collision, since that is the case where the ambiguity
# cannot be reasoned away.

{
    my $lines = lines_of(
        { rows => [ { nested => { who => 'inner' }, who => 'outer', id => 'R-1' } ] } );

    my %indents;
    for my $line ( @{$lines} ) {
        next if $line !~ /\bwho:/;
        push @{ $indents{ indent_of($line) } }, $line;
    }
    my @shared = grep { @{ $indents{$_} } > 1 } keys %indents;
    is_deeply( \@shared, [], 'two keys of the same name never share an indent' )
      or diag( join "\n", @{$lines} );
}

# --- nesting deeper than one level survives ------------------------------------------
#
# The first draft of the fix stripped each line's own indent and re-indented them
# all flat, which read correctly for one level and destroyed everything below it.
# Caught by testing a shape the fix was not aimed at.

{
    my $lines = lines_of( { rows => [ { a => { b => { c => 1 } }, d => 2 } ] } );
    my $a = line_with( $lines, qr/\ba:/ );
    my $b = line_with( $lines, qr/\bb:/ );
    my $c = line_with( $lines, qr/\bc:\s*1/ );
    ok( defined $a && defined $b && defined $c, 'all three levels are printed' );
    cmp_ok( indent_of($b), '>', indent_of($a), 'b is inside a' );
    cmp_ok( indent_of($c), '>', indent_of($b), 'and c is inside b, not beside it' );
}

# --- and everything the module already gets right is left alone ------------------------
#
# The override is narrow on purpose. These are the shapes it must NOT touch, and
# they are asserted because widening the predicate is exactly the mistake the
# first draft made.

{
    my $tabular = Tira->new->format_output( { rows => [ { a => 1, b => 2 }, { a => 9, b => 8 } ] } );
    like( $tabular, qr/rows\[2\]\{a,b\}:/,
        'an array of flat maps still uses the compact tabular form' );

    my $with_array = Tira->new->format_output(
        { rows => [ { answer => { mark => 'ok' }, tags => [ 'a', 'b' ], id => 'R-1' } ] } );
    like( $with_array, qr/\Qtags: [2]: a,b\E/,
        "an array beside a map keeps the module's own spelling, byte for byte" );
    like( $with_array, qr/answer:\s*\n/, 'while the map beside it is fixed' );
}

# --- an empty map says so without a trailing space --------------------------------------

{
    my $out = Tira->new->format_output( { rows => [ { meta => {}, id => 'R-1' } ] } );
    like( $out, qr/meta:\s*$/m, 'an empty map prints as a bare key' );
    unlike( $out, qr/meta: \n/, 'with no trailing space after the colon' );
}

# --- the two overrides compose --------------------------------------------------------
#
# lib/Tira.pm already patches _encode_primitive, because Data::TOON tests a scalar
# against a number pattern before it tests whether it needs quoting - so "2.20"
# encoded as 2.2, a different release. This override renders nested maps itself,
# and if it reached for the module's primitive encoder instead of the patched one,
# that fix would silently stop applying inside any nested map.
#
# Caught by probing a shape the fix was not aimed at, in a harness that did not
# load Tira: the prototype printed "ver: 2.2" and it took a moment to see that was
# the harness rather than the fix. Asserted here so the question is never open.

{
    my $out = Tira->new->format_output(
        { rows => [ { a => { ver => '2.20' }, b => '1.10' } ] } );
    like( $out, qr/ver:\s*"2\.20"/,
        'a numeric-looking string inside a nested map is still quoted' );
    like( $out, qr/b:\s*"1\.10"/,
        'and so is one beside it, which was already true' );
}

# --- a multi-line value that is not a map sits under its own key -------------------------
#
# An array of arrays is the shape that reaches here. The first version of this
# override put its header level with the key it belonged to, which is the same
# ambiguity being fixed, reintroduced one layer along.

{
    my $out = Tira->new->format_output(
        { rows => [ { a => { m => 1 }, b => [ [ 1, 2 ], [ 3, 4 ] ] } ] } );
    my @lines = split /\n/, $out;
    my ($key)    = grep { /\bb:\s*$/ } @lines;
    my ($header) = grep { /\[2\]:\s*$/ } @lines;
    ok( defined $key && defined $header, 'the key and its array header both appear' );
    cmp_ok( indent_of($header), '>', indent_of($key),
        "the array's header is inside its key, not beside it" )
      if defined $key && defined $header;
}

# --- proved by putting the module's line back ---------------------------------------------
#
# Every assertion above is about indentation, and indentation assertions pass
# easily against output that never contained the subject at all. So the override
# is disabled here and the ambiguity must come back.
#
# A single-key nested map will not do it: its one key sits inline with the
# parent key ("nested:     who: inner"), never lands on its own line, and so
# never collides with a sibling at the same indent - found by running this
# exact case and getting indents 2 and 4, not two matches at one indent. The
# original shape (answer with three keys, only the first inline) is what
# reliably reproduces the collision, because its second and third keys land on
# their own lines at the same indent as the question's own keys.

{
    my $shape = { questions => [
        { answer => { author => 'michael', mark => 'ok', text => 'yes' },
          author => 'claude', id => 'Q-1', text => 'is it stored?' } ] };

    my $repaired = Tira->new->format_output($shape);

    no warnings 'redefine';
    local *Data::TOON::Encoder::_encode_object_with_array = $Tira::TOON_ARRAY_BEFORE;

    my $broken = Tira->new->format_output($shape);

    isnt( $broken, $repaired, 'the override is what makes the difference' );

    my @who = grep { /\btext:/ } split /\n/, $broken;
    my %seen;
    $seen{ indent_of($_) }++ for @who;
    ok( ( grep { $_ > 1 } values %seen ),
        'and without it, two text: keys land at one indent again' )
      or diag($broken);
}

done_testing;

__END__

=head1 NAME

272-a-map-printed-inside-its-parent.t - TKT-386

=head1 DESCRIPTION

C<Data::TOON> rendered a map nested inside a list element flattened into its
parent, so its keys sat at the parent's indent and a reader could not tell whose
key was whose. Tira now overrides the one encoder method responsible, delegating
every shape the module renders correctly and taking over only for a list item
carrying a map. Round-tripping is not addressed here - the decoder has a matching
gap, recorded as TKT-393.

=cut
