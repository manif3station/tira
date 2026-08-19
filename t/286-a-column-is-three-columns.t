#!/usr/bin/env perl
# column.list required --type and answered for one record kind, silently -
# the same shape TKT-342 already fixed for column.endings, for the reason
# TKT-331 measured the cost of: a column name is really three separate
# columns underneath, and a caller checking whether one is silenced had to
# call this three times and compare by hand, or - more likely - check one
# type, see watched=0, and believe the column is silenced everywhere.
#
# Measured: a board silenced --type ticket for a column via
# tira.column.update --no-watch. An epic sitting in the SAME COLUMN NAME kept
# reading watched=1 and fired checklist-unmoved correctly - not a bug, but
# invisible from a single column.list call, which is what made a real,
# working rule read as broken from outside.
#
# column_roles already answers this identical "no --type given" ambiguity by
# returning a hash keyed by all three types rather than guessing one; this
# follows that same precedent, established a second time by TKT-342 for
# column_endings.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-19T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Threefold', dir => $root, members => ['claude'],
    columns      => ['backlog, in-review, done'],
    epic_columns => ['backlog, in-review, done'],
    sow_prefix => 'THS', epic_prefix => 'THE', ticket_prefix => 'THT',
);

# The reported shape: the same column NAME, silenced for one type only.
$tira->column_update( project => $root, type => 'ticket', name => 'in-review', watched => 0 );

# --- without --type, every type is answered, not one -------------------------

{
    my $all = $tira->column_list( project => $root );
    is( ref $all, 'HASH', 'without a type, the answer is keyed by type rather than a flat list' );
    is_deeply( [ sort keys %{$all} ], [qw(epic sow ticket)],
        'and names all three, so the scope is visible rather than assumed' );
}

# --- and it agrees with asking per type directly ------------------------------

{
    my $all    = $tira->column_list( project => $root );
    my $ticket = $tira->column_list( project => $root, type => 'ticket' );
    my $epic   = $tira->column_list( project => $root, type => 'epic' );

    is_deeply( $all->{ticket}, $ticket, 'the bundled ticket answer matches asking for ticket directly' );
    is_deeply( $all->{epic}, $epic, 'and the bundled epic answer matches asking for epic directly' );

    # The exact reported case: the same column name, watched for one type
    # and not the other, visible in one read rather than three.
    my ($ticket_col) = grep { $_->{name} eq 'in-review' } @{ $all->{ticket} };
    my ($epic_col)   = grep { $_->{name} eq 'in-review' } @{ $all->{epic} };
    is( $ticket_col->{watched}, 0, "ticket's in-review reads unwatched, as declared" );
    is( $epic_col->{watched}, 1,
        "and epic's in-review still reads watched, visible in the SAME call rather than a second one" );
}

# --- naming a type is unchanged - still a flat list, not wrapped -------------

{
    my $ticket = $tira->column_list( project => $root, type => 'ticket' );
    is( ref $ticket, 'ARRAY', 'naming a type still returns a flat list, as it always did' );
    my @names = map { $_->{name} } @{$ticket};
    is_deeply( \@names, [qw(backlog in-review done discard)], 'and the answer itself is unchanged' );
}

# --- proved by reverting to the single-type default --------------------------

{
    no warnings 'redefine';
    local *Tira::column_list = sub {
        my ( $self, %args ) = @_;
        my ( undef, $config ) = $self->_board_data(%args);
        return Tira::_column_defaults( $config->{columns} );
    };

    my $reverted = eval { $tira->column_list( project => $root ) };
    my $error    = $@;
    ok( !$reverted, 'without the fix, no --type refuses outright again - the exact defect' );
    like( $error, qr/needs --type/, 'naming the same refusal column_list always had for a missing type' );
}

done_testing;

__END__

=head1 NAME

286-a-column-is-three-columns.t - TKT-409

=head1 DESCRIPTION

C<column.list> required C<--type> and answered for one record kind only, so
a column silenced for one type read as silenced everywhere from a single
call - the cost TKT-331 measured. It now follows the precedent
C<column_roles> and C<column_endings> (TKT-342) already set for the
identical ambiguity: without a type, the answer is a hash keyed by all
three, so the same column name's differing settings across record kinds are
visible in one read rather than three.

=cut
