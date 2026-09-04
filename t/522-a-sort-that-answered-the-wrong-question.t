#!/usr/bin/env perl
# A sort spec the code does not understand, answered anyway.
#
# TKT-888, EPC-007. `tasklist.list --sort` accepts a direction it cannot honour
# and a field that does not exist, and gives a wrong answer that looks like a
# right one. Reproduced when the card was filed, three items with status 0, 1, 2:
#
#   status:asc         -> A(0),B(1),C(2)     correct
#   status:desc        -> C(2),B(1),A(0)     correct
#   status:DESC        -> A(0),B(1),C(2)     ASCENDING - the opposite of the ask
#   status:descending  -> A(0),B(1),C(2)     ASCENDING
#   bogus:desc         -> A(0),B(1),C(2)     NO SORT AT ALL
#   status:sideways    -> A(0),B(1),C(2)     ASCENDING
#
# Both halves live in one expression:
#
#   [ $field, ( ( $dir // 'asc' ) eq 'desc' ? -1 : 1 ) ];
#
# Anything that is not the exact string 'desc' means ascending, and an unknown
# field falls through to comparing two undefs - which is always 0, so no sort
# happens at all.
#
# THE DECISION THIS CARD ASKED FOR, recorded here as well as on the card:
# DESC IS ACCEPTED, anything else is refused. SQL writes DESC, every spreadsheet
# writes DESC, and somebody typing it means desc unambiguously - refusing it
# would be pedantry. What was never defensible is silently returning the
# opposite. `descending` and `sideways` are refused, because the code cannot
# know that the first means desc and the second means nothing.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'Sort', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'SRS', epic_prefix => 'SRE', ticket_prefix => 'SRT',
    );
    my @made;
    for my $text (qw(A B C)) {
        push @made, $tira->tasklist_add( project => $root, text => $text );
    }
    # Statuses 0, 1, 2 so a direction is visible in the answer.
    $tira->tasklist_update( project => $root, id => $made[1]{id}, status => 'working' );
    $tira->tasklist_update( project => $root, id => $made[2]{id}, status => 'done' );
    return ( $tira, $root );
}

sub texts {
    my ( $tira, $root, $sort ) = @_;
    my $list = $tira->tasklist_list( project => $root,
        ( defined $sort ? ( sort => $sort ) : () ) );
    my $items = ref $list eq 'HASH' ? ( $list->{items} || $list->{tasks} ) : $list;
    return join ',', map { $_->{text} } @{ $items || [] };
}

# --- what already works, and must go on working ------------------------------
#
# The controls. A refusal that also broke these would be a worse bug than the
# one it fixed, and every tasklist read on the board goes through this sort.

{
    my ( $tira, $root ) = board();

    is( texts( $tira, $root, 'status:asc' ), 'A,B,C',
        'status:asc is unchanged' );

    is( texts( $tira, $root, 'status:desc' ), 'C,B,A',
        'and status:desc is unchanged - the two specs that always worked' );

    is( texts( $tira, $root, 'status' ), 'A,B,C',
        'a field with no direction still means ascending, which is the grammar '
          . 'the manual documents' );

    my $default = texts( $tira, $root, undef );
    like( $default, qr/\A[ABC](?:,[ABC]){2}\z/,
        'and a read with no --sort at all still works - it uses the default '
          . 'last_updated:desc,status:asc, which every tasklist read and the '
          . 'dashboard poll depend on' );

    is( texts( $tira, $root, 'last_updated:desc,status:asc' ), $default,
        'the default spec passed explicitly gives the same answer, so the '
          . 'refusal cannot break the one spec the board uses constantly' );
}

# --- DESC is accepted, because it means desc ---------------------------------

{
    my ( $tira, $root ) = board();

    is( texts( $tira, $root, 'status:DESC' ), 'C,B,A',
        'DESC IS DESCENDING. It is what SQL writes and what every spreadsheet '
          . 'writes, and somebody typing it means desc - today it silently '
          . 'returns ASCENDING, which is the opposite of the ask and the worst '
          . 'kind of wrong because it looks like an answer' );

    is( texts( $tira, $root, 'status:Desc' ), 'C,B,A',
        'and so is any other capitalisation - the case is not the caller saying '
          . 'something different' );
}

# --- and anything the code cannot honour is REFUSED --------------------------
#
# Not accepted-and-ignored, which is the fault this codebase names by name
# beside --show-logs: "a flag that parses and does nothing reads as
# confirmation". A sort is worse than a flag, because it hands back a list in an
# order the caller did not ask for and has no reason to doubt.

{
    my ( $tira, $root ) = board();

    for my $direction (qw(descending sideways ascending up)) {
        # any failure is what this means: the only intended way out is the
        # refusal, and a failure for another reason is equally a spec that was
        # not honoured.
        my $ok = eval { texts( $tira, $root, "status:$direction" ); 1 };
        my $why = $@ // '';

        ok( !$ok, "a direction of '$direction' is refused rather than quietly "
              . 'read as ascending' );
        like( $why, qr/\Q$direction\E/,
            'and the refusal says what was given, so the caller can see their '
              . 'own typo rather than guess at it' );
        like( $why, qr/asc/i,
            'and what is accepted instead' );
    }
}

{
    my ( $tira, $root ) = board();

    my $ok = eval { texts( $tira, $root, 'bogus:desc' ); 1 };
    my $why = $@ // '';

    ok( !$ok, 'AN UNKNOWN FIELD IS REFUSED. Today it returns the list in no '
          . 'order at all - two undefs compare equal, so the sort is a no-op '
          . 'and the caller gets an unsorted list dressed as a sorted one' );

    like( $why, qr/bogus/, 'the refusal names the field that does not exist' );

    like( $why, qr/\bstatus\b/,
        'and names ones that do, so the caller can correct it without reading '
          . 'the source' );
}

# --- the refusal is the ENGINE's, so every caller is guarded -----------------
#
# The CLI is not the only way in. The browser dashboard reads the tasklist
# through a provider on a one-second timer, and a check that lived in the option
# parser would leave that route answering wrongly - which is how the engine and
# the browser came to disagree about attachment content types on TKT-713.

{
    my ( $tira, $root ) = board();

    my $ok = eval { $tira->tasklist_list( project => $root, sort => 'bogus:desc' ); 1 };
    ok( !$ok,
        'the engine itself refuses, called directly with no CLI in the way - so '
          . 'the browser route is guarded by the same rule rather than by a '
          . 'second copy of it' );
}

done_testing();

__END__

=head1 NAME

522-a-sort-that-answered-the-wrong-question.t - refusing a spec it cannot honour

=head1 WHY

TKT-888. C<tasklist.list --sort> read C<DESC> as ascending and ignored an unknown
field entirely, returning a wrong answer that looked like a right one.

=head1 WHAT IS ASSERTED

That the specs which always worked still do, including the default the dashboard
polls with; that C<DESC> in any capitalisation is descending; that a direction
the code cannot honour is refused, naming what was given and what is accepted;
that an unknown field is refused, naming fields that exist; and that the refusal
comes from the engine rather than the option parser, so the browser route is
guarded by the same rule.

=cut
