package Tira::Toon;

# The TOON encoder/decoder overrides, lifted out of Tira.pm so that reading
# the engine to change one command no longer means reading these too. TKT-746.
#
# TOON is the default output and the one every agent reads, and Data::TOON has
# three shapes it gets wrong: a numeric-looking string loses its own quoting
# (2.20 read back as 2.2), a map nested inside a list item flattens into the
# map around it on the way out, and the matching decoder cannot read that
# nested shape back in even when it is written correctly. Each override below
# delegates to the original for every shape it already renders correctly and
# only replaces the branch that is wrong - see the comment on each for the
# full account of what broke and how it was found.
#
# LOADED LAZILY. Tira.pm requires this only from inside format_output's 'toon'
# branch, the one caller that needs it - a command asking for json or human
# output never compiles it. t/483 asserts both halves of that: this module
# compiles and applies its patches standalone, without Tira.pm having been
# loaded first, and a format_output call that does not ask for toon leaves
# Tira::Toon out of %INC.
#
# THE GLOBALS KEEP THEIR OLD NAME. $Tira::TOON_PRIMITIVE_BEFORE,
# $Tira::TOON_ARRAY_BEFORE and $Tira::TOON_ARRAY_DECODE_BEFORE are read by
# three existing test files to restore the original Data::TOON subs and prove
# the override actually changed the answer - a lift is a move, not a rename,
# so the values are aliased into the Tira:: package under the same names they
# had when this code lived there.

use strict;
use warnings;

use B ();
use Data::TOON::Encoder;
use Data::TOON::Decoder;

our $TOON_PRIMITIVE_BEFORE = \&Data::TOON::Encoder::_encode_primitive;
our $TOON_ARRAY_BEFORE     = \&Data::TOON::Encoder::_encode_object_with_array;
our $TOON_ARRAY_DECODE_BEFORE = \&Data::TOON::Decoder::_decode_array_value;

{
    no warnings 'once';
    *Tira::TOON_PRIMITIVE_BEFORE    = \$TOON_PRIMITIVE_BEFORE;
    *Tira::TOON_ARRAY_BEFORE        = \$TOON_ARRAY_BEFORE;
    *Tira::TOON_ARRAY_DECODE_BEFORE = \$TOON_ARRAY_DECODE_BEFORE;
}

sub _toon_is_string {
    my ($value) = @_;
    return 0 if ref $value;
    my $flags = B::svref_2object( \$value )->FLAGS;
    return 0 if !( $flags & B::SVp_POK() );
    return 0 if $flags & ( B::SVp_IOK() | B::SVp_NOK() );
    return 1;
}

{
    no warnings 'redefine';
    *Data::TOON::Encoder::_encode_primitive = sub {
        my ( $self, $value ) = @_;
        my $encoded = $TOON_PRIMITIVE_BEFORE->( $self, $value );
        return $encoded if !defined $value || !defined $encoded;
        return $encoded if !_toon_is_string($value);
        return $encoded if $encoded eq $value;
        return $encoded if $encoded =~ /\A"/;
        return '"' . $self->_escape_string($value) . '"';
    };
}

sub _toon_item_carries_map {
    my ($array) = @_;
    return 0 if ref $array ne 'ARRAY';
    for my $item ( @{$array} ) {
        next if ref $item ne 'HASH';
        return 1 if grep { ref $_ eq 'HASH' } values %{$item};
    }
    return 0;
}

{
    no warnings 'redefine';
    *Data::TOON::Encoder::_encode_object_with_array = sub {
        my ( $self, $indent, $key, $array ) = @_;
        return $TOON_ARRAY_BEFORE->( $self, $indent, $key, $array )
          if !_toon_item_carries_map($array);

        my @lines = ( $indent . $key . '[' . scalar( @{$array} ) . ']:' );
        local $self->{depth} = $self->{depth} + 1;
        my $item_indent  = ' ' x ( $self->{depth} * $self->{indent} );
        my $field_indent = ' ' x ( ( $self->{depth} + 1 ) * $self->{indent} );

        for my $obj ( @{$array} ) {
            my @keys = $self->_sort_fields( keys %{$obj} );
            if ( !@keys ) { push @lines, $item_indent . '-'; next }

            for my $i ( 0 .. $#keys ) {
                my $k     = $keys[$i];
                my $value = $obj->{$k};

                my $lead = $i == 0 ? $item_indent . '- ' : $field_indent;
                my $own  = $i == 0 ? $item_indent . '  ' : $field_indent;

                if ( ref $value ne 'HASH' ) {
                    local $self->{depth} = $self->{depth} + 1;
                    my $v = $self->_encode_value($value);
                    $v = '' if !defined $v;
                    my @sub = split /\n/, $v;
                    if ( @sub <= 1 ) { push @lines, $lead . "$k: $v"; next }
                    push @lines, $lead . "$k:";
                    push @lines, $own . ( ' ' x $self->{indent} ) . $_ for @sub;
                    next;
                }

                if ( !%{$value} ) { push @lines, $lead . "$k:"; next }

                local $self->{depth} = $self->{depth} + 1;
                my $body = $self->_encode_object($value);
                my @sub = split /\n/, ( defined $body ? $body : '' );

                my $least;
                for my $line (@sub) {
                    next if $line !~ /\S/;
                    my ($lead_ws) = $line =~ /\A(\s*)/;
                    $least = length $lead_ws
                      if !defined $least || length($lead_ws) < $least;
                }
                $least //= 0;
                my $body_indent = $own . ( ' ' x $self->{indent} );
                push @lines, $lead . "$k:";
                push @lines, $body_indent . substr( $_, $least ) for @sub;
            }
        }
        return join "\n", @lines;
    };
}

{
    no warnings 'redefine';
    *Data::TOON::Decoder::_decode_array_value = sub {
        my ( $self, $bracket_part, $fields_part, $rest ) = @_;

        return $TOON_ARRAY_DECODE_BEFORE->( $self, $bracket_part, $fields_part, $rest )
          if $fields_part || $bracket_part !~ /^\[(\d+)([\t|])?\]/;

        my $delimiter = defined $2 ? $2 : ',';

        my $has_list_format = 0;
        my $peek_pos        = $self->{pos};
        while ( $peek_pos < @{ $self->{lines} } ) {
            my $peek_line = $self->{lines}[$peek_pos];
            if ( !$peek_line || $peek_line =~ /^\s*$/ ) { $peek_pos++; next }
            last if $self->_get_depth($peek_line) <= 0;
            my $peek_trimmed = $peek_line;
            $peek_trimmed =~ s/^\s+//;
            if ( $peek_trimmed =~ /^-/ ) { $has_list_format = 1; last }
            last;
        }
        return $TOON_ARRAY_DECODE_BEFORE->( $self, $bracket_part, $fields_part, $rest )
          if !$has_list_format;

        my @items;
        while ( $self->{pos} < @{ $self->{lines} } ) {
            my $line = $self->{lines}[ $self->{pos} ];
            if ( !$line || $line =~ /^\s*$/ ) { $self->{pos}++; next }
            my $depth = $self->_get_depth($line);
            last if $depth <= 0;
            my $trimmed = $line;
            $trimmed =~ s/^\s+//;
            last if $trimmed !~ /^-\s(.*)$/;
            $self->{pos}++;
            my $item_content = $1;

            if ( $item_content !~ /^(\w+):\s*(.*)$/ ) {
                push @items, $self->_parse_primitive($item_content);
                next;
            }
            my ( $first_key, $first_value ) = ( $1, $2 );
            my $item = {};

            $item->{$first_key} = $first_value =~ /^\s*$/
              ? $self->_decode_object( $depth + 2 )
              : $self->_parse_primitive($first_value);

            while ( $self->{pos} < @{ $self->{lines} } ) {
                my $next_line = $self->{lines}[ $self->{pos} ];
                if ( !$next_line || $next_line =~ /^\s*$/ ) { $self->{pos}++; next }
                my $next_depth = $self->_get_depth($next_line);
                last if $next_depth != $depth + 1;
                my $next_trimmed = $next_line;
                $next_trimmed =~ s/^\s+//;
                last if $next_trimmed =~ /^-/;
                last if $next_trimmed !~ /^(\w+):\s*(.*)$/;
                my ( $sub_key, $sub_rest ) = ( $1, $2 );
                $self->{pos}++;

                $item->{$sub_key} = length($sub_rest)
                  ? $self->_parse_primitive($sub_rest)
                  : $self->_decode_object( $next_depth + 1 );
            }
            push @items, $item;
        }
        return \@items;
    };
}

1;

__END__

=head1 NAME

Tira::Toon - Data::TOON encoder/decoder overrides for Tira's default output

=head1 DESCRIPTION

Fixes three C<Data::TOON> shapes that render or read back wrong: a
numeric-looking string loses its quoting on the way out, a map nested inside
a list item flattens into the map around it, and the decoder cannot read
that nested shape back in even when written correctly. Loaded with C<require>
from C<Tira::format_output>'s C<toon> branch only - see that sub in
F<lib/Tira.pm> for the call site, and the comment on each override below for
the full account of the defect it closes.

Loading this module applies its patches to C<Data::TOON::Encoder> and
C<Data::TOON::Decoder> as a side effect of the C<require>; there is nothing
else to call.

=cut
