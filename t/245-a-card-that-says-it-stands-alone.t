#!/usr/bin/env perl
# A card that says it stands alone is not an orphan.
#
# Whether a card is legitimately parentless is decided in three places, and one
# of them disagreed. The engine's own definition of a complete card honours the
# standalone label - a card carrying it is not missing a parent. The push gate
# honours it in the same words. The command reference says so out loud: "a card
# labelled standalone is saying somebody meant it to have none."
#
# orphan-card had never heard of it, and reported any card with no parent.
#
# Measured on this project's own board at 16:07 on 2026-08-16: 84 outstanding
# violations, every one orphan-card, every one at critical tone, every one seen
# twelve times since 06:33, and every one of the 84 carrying the label. The
# loudest thing on the bridge was a rule shouting about a declaration the rest
# of the tool accepts, on finished work, for ever - and the owner reads that
# bridge. He has said before that a rule reporting the same unactionable thing
# for ever is worse than no rule.
#
# The same shape as the definition of a complete card, which used to be written
# twice, and where work ends, which used to be worked out twice. The answer is
# the same: ask the one place that decides.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Alone', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ALS', epic_prefix => 'ALE', ticket_prefix => 'ALT',
);
$tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );

my $declared = $tira->create_record( project => $root, type => 'ticket',
    title => 'Raised on its own, deliberately', labels => ['standalone'] );

my $accidental = $tira->create_record( project => $root, type => 'ticket',
    title => 'Nobody said where this belongs' );

sub orphaned {
    my $pass = $tira->police_pass( project => $root,
        store => File::Spec->catdir( $tmp, 'police' ), world => {} );
    return { map { $_->{ref} => 1 }
          grep { ( $_->{rule} // '' ) eq 'orphan-card' } @{ $pass->{violations} } };
}

# --- the engine already answers this ------------------------------------------
#
# Asserted first, because the fix is the rule asking this question rather than a
# new opinion about labels.

{
    my $missing = $tira->card_missing( project => $root, ref => $declared->{ref} );
    is( scalar( grep { $_ eq 'parent' } @{$missing} ), 0,
        'the engine does not call a standalone card parentless' );

    my $other = $tira->card_missing( project => $root, ref => $accidental->{ref} );
    is( scalar( grep { $_ eq 'parent' } @{$other} ), 1,
        'while a card that said nothing is missing one' );
}

# --- and the rule agrees with it ----------------------------------------------

{
    my $reported = orphaned();

    ok( !$reported->{ $declared->{ref} },
        'a card that says it stands alone is not reported as an orphan' );
    ok( $reported->{ $accidental->{ref} },
        'while a card with no parent and nothing said about it still is' );
}

# --- and a statement of work is still exempt ----------------------------------
#
# It sits at the top of the tree, so it has no parent to be missing - which the
# rule always knew and must go on knowing.

{
    my $sow = $tira->create_record( project => $root, type => 'sow',
        title => 'The top of the tree' );
    my $reported = orphaned();
    ok( !$reported->{ $sow->{ref} }, 'a statement of work is not an orphan either' );
}

# --- proved by giving the rule its own idea back ------------------------------
#
# With the engine's answer replaced by the rule's old one - anything without a
# parent - the declared card is reported again, which is the state this board
# was in with 84 criticals on the bridge.

{
    no warnings 'redefine';
    local *Tira::_card_missing_from = sub {
        my ( $self, $record ) = @_;
        return [ ( $record->{type} // '' ) eq 'sow' || $record->{parent} ? () : 'parent' ];
    };

    my $reported = orphaned();
    ok( $reported->{ $declared->{ref} },
        'without the engine\'s answer the declared card is an orphan again' );
    ok( $reported->{ $accidental->{ref} }, 'and so is the accidental one' );
}

# --- and back again -----------------------------------------------------------

{
    my $reported = orphaned();
    ok( !$reported->{ $declared->{ref} }, 'and the declaration is honoured once more' );
}

done_testing;

__END__

=head1 NAME

245-a-card-that-says-it-stands-alone.t - one answer about a card with no parent

=head1 DESCRIPTION

C<orphan-card> reported any card without a parent, including the ones carrying
the C<standalone> label that the engine, the push gate and the command
reference all treat as a declaration that it has none. On this project's board
that was 84 critical violations, seen twelve times each, none of them
actionable.

The rule asks the engine now, so the exception is decided where it was already
written down.

=cut
