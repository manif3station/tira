#!/usr/bin/env perl
# Without --type, endings answers for every type - not one, silently.
#
# Reported, and verified live against the installed 2.70 before writing this:
#
#   d2 tira.column.endings                -> [1]: done
#   d2 tira.column.endings --type ticket  -> [4]: deployed-on-demo, discard, done, samples
#
# Read cold, the first answer says this board has exactly one ending column -
# which would mean three real endings were being treated as live work, and the
# project's own changelog already records what that costs another board: 171
# card-unassigned findings in a single pass. The bare answer carried no sign
# that it was scoped, so it read as a global statement rather than one type's.
#
# column_roles already answers this exact ambiguity, in the same file, for the
# same shape of question - "which column plays role X" is per type, and asking
# without naming one answers for all three rather than guessing. This follows
# that precedent rather than inventing a refusal: column.update already has one
# ("This command needs --type ticket, epic or sow") for the write side, where a
# silent default would be a mistake made FOR the caller; this is a read, where
# the mistake is a wrong belief formed BY the caller; the fix for a read is to
# say the scope, not to refuse to answer.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-18T20:55:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Ends', dir => $root, members => ['claude'],
    columns       => ['backlog, implement, done'],
    epic_columns  => ['backlog, implement, done, archived'],
    sow_prefix => 'EDS', epic_prefix => 'EDE', ticket_prefix => 'EDT',
);
$tira->column_update( project => $root, type => 'epic', name => 'archived', terminal => 1 );

# --- without --type, every type is answered, not one -----------------------------------

{
    my $all = $tira->column_endings( project => $root );
    is( ref $all, 'HASH', 'without a type, the answer is keyed by type rather than a flat list' );
    is_deeply( [ sort keys %{$all} ], [qw(epic sow ticket)],
        'and names all three, so the scope is visible rather than assumed' );
}

# --- and it agrees with asking per type directly ----------------------------------------

{
    my $all    = $tira->column_endings( project => $root );
    my $ticket = $tira->column_endings( project => $root, type => 'ticket' );
    my $epic   = $tira->column_endings( project => $root, type => 'epic' );

    is_deeply( $all->{ticket}, $ticket, "the bundled ticket answer matches asking for ticket directly" );
    is_deeply( $all->{epic}, $epic, 'and the bundled epic answer matches asking for epic directly' );

    # The case that started this: epic has a real second ending the flat,
    # type-blind answer used to hide entirely.
    ok( ( grep { $_ eq 'archived' } @{ $all->{epic} } ),
        "epic's real ending, archived, is visible in the bundled answer" );
}

# --- naming a type is unchanged - still a flat list, not wrapped -----------------------

{
    my $ticket = $tira->column_endings( project => $root, type => 'ticket' );
    is( ref $ticket, 'ARRAY', 'naming a type still returns a flat list, as it always did' );
    is_deeply( $ticket, ['done'], 'and the answer itself is unchanged' );
}

# --- proved by reverting to the single-type default --------------------------------------

{
    no warnings 'redefine';
    local *Tira::column_endings = sub {
        my ( $self, %args ) = @_;
        my $root = $self->discover_project(%args);
        return [ sort keys %{ $self->_ending_columns( $root, $args{type} ) } ];
    };

    my $reverted = $tira->column_endings( project => $root );
    is( ref $reverted, 'ARRAY',
        'without the fix, no --type silently answers as a flat list again - the exact defect' );
    ok( !( grep { $_ eq 'archived' } @{$reverted} ),
        "and epic's real ending is invisible in that flat answer, matching what was reported" );
}

done_testing;

__END__

=head1 NAME

278-scope-is-said-not-assumed.t - TKT-342

=head1 DESCRIPTION

C<tira.column.endings> with no C<--type> answered silently as one type's
result, with nothing in the output marking it as scoped - read cold, "one
ending column" looked like a fact about the whole board rather than one
type's answer. It now follows the same precedent C<column_roles> already
sets for the identical ambiguity: without a type, the answer is a hash keyed
by type rather than a guess at which one was meant.

=cut
