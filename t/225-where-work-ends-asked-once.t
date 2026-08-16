#!/usr/bin/env perl
# Where work ends, asked once and answered once.
#
# Four rules need to know which columns are endings. There is a helper that
# answers it - protected or terminal, with done standing in when a board has
# marked nothing - and two of the four called it. card-unassigned built the
# same thing inline and priority-skipped built it inline again in a different
# shape. All three agreed, which is the condition under which nobody notices
# they are three: a change to the helper would have reached half the rules and
# left the others behind, silently.
#
# That is the shape this project keeps finding, and it has already cost it a
# dashboard, a documentation guard and a set of required fields. I went looking
# for it here an hour after adding a fourth caller of my own.
#
# Proved by changing the answer rather than by reading the code. The helper is
# replaced for the length of this test and every rule that needs it has to
# follow - a rule with its own copy cannot.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $store = File::Spec->catdir( $tmp, 'store' );

my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Endings', dir => $root, members => ['claude'],
    columns => ['backlog, implement, shipped, done'],
    sow_prefix => 'WES', epic_prefix => 'WEE', ticket_prefix => 'WET',
);

$tira->policy_add( project => $root, rule => 'card-unassigned', action => 'bridge-reminder' );

# A card nobody is assigned to, sitting in a column that is not an ending, so
# card-unassigned has something to say about it.
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Nobody is on this' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'shipped' );

sub speaks_about {
    my ($rule) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return scalar grep { ( $_->{rule} // '' ) eq $rule } @{ $pass->{violations} };
}

# --- as the board stands ---------------------------------------------------
#
# shipped is not marked as an ending, so it is a column work happens in and the
# card in it is unassigned. Asserted first so what follows is a change of
# answer rather than a rule with nothing to say.

ok( speaks_about('card-unassigned'),
    'a card nobody is on, in a column that is not an ending, is reported' );

# --- and when the answer changes -------------------------------------------
#
# The helper is replaced, not the board. A rule that asks follows; a rule with
# its own copy carries on regardless, which is the whole point.

{
    no warnings 'redefine';
    local *Tira::_resting_columns = sub {
        my ( $self, $root, $type ) = @_;
        return { shipped => 1 };
    };

    is( speaks_about('card-unassigned'), 0,
        'and stops being reported when the helper says that column is where work ends' );
}

# --- and back again ---------------------------------------------------------
#
# So the silence above is the changed answer and not something that happened to
# the board on the way past.

ok( speaks_about('card-unassigned'),
    'and is reported again once the helper answers as it did before' );

done_testing;

__END__

=head1 NAME

225-where-work-ends-asked-once.t - one question, one answer

=head1 DESCRIPTION

Four rules ask which columns are endings and three pieces of code answered it.
They agreed, which is why nobody noticed: a change to the helper would have
reached the rules that call it and left the ones with their own copies behind.

Proved by changing the answer rather than by reading the code - the helper is
replaced for the length of the test, and a rule that keeps its own copy cannot
follow.

=cut
