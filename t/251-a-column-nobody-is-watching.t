#!/usr/bin/env perl
# A column the board is not watching is left alone by every card rule.
#
# Reported by Zenandi, measured rather than inferred: they set in-review to
# --no-watch on all three record types at 02:08, moved a card into it at 02:22,
# and checklist-unmoved fired on it at 02:24. All nine of their outstanding
# findings were that rule, every one on a card in that column - while
# card-still, declared at the same moment against the same column config,
# correctly said nothing about any of them.
#
# Their own correction is worth keeping: they first wrote that the finding
# "cannot be cleared", and then watched nine of them clear at once when the
# next real piece of work was done and ticked. So the rule is answerable; what
# it should not be doing is speaking about a column somebody switched off.
#
# The gap is the one this project found from the other side the same night. The
# watched flag has existed since columns carried it, tira.stale has judged cards
# by it all along, and exactly one police rule read it - card-still, shipped
# hours before this report arrived. Every other card rule ignored it.
#
# So it is answered once, where the rules already ask which columns to leave
# alone: a card resting in the backlog, a card finished in an ending, and now a
# card in a column nobody is watching.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-17T09:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Unwatched', dir => $root, members => ['claude'],
    columns => ['backlog, implement, in-review, done'],
    sow_prefix => 'UWS', epic_prefix => 'UWE', ticket_prefix => 'UWT',
);
$tira->policy_add( project => $root, rule => 'checklist-unmoved',
    action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Waiting on a person' );
$tira->checklist_add( project => $root, ref => $card->{ref},
    item => 'the work itself', status => 'todo' );

$now = '2026-08-17T10:00:00Z';
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );

sub unmoved {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return scalar grep { ( $_->{rule} // '' ) eq 'checklist-unmoved' }
      @{ $pass->{violations} };
}

# --- a watched column, so the rule has something to say ------------------------
#
# Asserted first, so what follows is a column being switched off rather than a
# rule with nothing to say about this card.

$now = '2026-08-17T11:00:00Z';
$tira->record_move( project => $root, ref => $card->{ref}, column => 'in-review' );

ok( unmoved(), 'a card moved on with nothing ticked is reported' );

# --- and the same card, once the column is switched off ------------------------
#
# Nothing about the card changes: only whether the board is watching where it
# sits, which is what Zenandi set fourteen minutes before the rule fired.

{
    $tira->column_update( project => $root, type => $_, name => 'in-review', watched => 0 )
      for qw(sow epic ticket);

    is( unmoved(), 0,
        'a card in a column set to --no-watch is not reported' );
}

# --- and watching it again brings it back --------------------------------------
#
# The switch is a switch, not a way of deleting a finding.

{
    $tira->column_update( project => $root, type => $_, name => 'in-review', watched => 1 )
      for qw(sow epic ticket);

    ok( unmoved(), 'and switching the column back on reports it again' );
}

# --- every card rule, not just this one ----------------------------------------
#
# The report was about checklist-unmoved because that is the rule they had
# declared. The gap was that one rule read the flag and the rest did not, so
# fixing the one they met would have sent the next report about the next rule.

{
    $tira->column_update( project => $root, type => $_, name => 'in-review', watched => 0 )
      for qw(sow epic ticket);
    $tira->policy_add( project => $root, rule => 'card-unassigned',
        action => 'bridge-reminder' );
    $tira->policy_add( project => $root, rule => 'card-duration',
        action => 'bridge-reminder', column => 'in-review', age => '1m' );

    $now = '2026-08-17T14:00:00Z';
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    my @about = grep { ( $_->{ref} // '' ) eq $card->{ref} } @{ $pass->{violations} };

    is_deeply( [ sort map { $_->{rule} } @about ], [],
        'no card rule speaks about a card in a column nobody is watching' );
}

# --- proved by asking only about resting columns again -------------------------
#
# With the answer narrowed back to protected and terminal - what it was before
# this - the unwatched column stops being excluded and the reports return.

{
    no warnings 'redefine';
    local *Tira::_resting_columns = sub {
        my ( $self, $root, $type ) = @_;
        my $columns = eval { $self->column_list( project => $root, type => $type ) } || [];
        my %resting = map { $_->{name} => 1 }
          grep { $_->{protected} || $_->{terminal} } @{$columns};
        $resting{done} = 1 if !grep { $_->{terminal} } @{$columns};
        return \%resting;
    };

    ok( unmoved(),
        'reading only the resting columns reports the card again, which is what was reported' );
}

done_testing;

__END__

=head1 NAME

251-a-column-nobody-is-watching.t - --no-watch, honoured by every card rule

=head1 DESCRIPTION

C<--no-watch> has existed since columns carried it and C<tira.stale> has judged
cards by it all along, but exactly one police rule read it. Zenandi set a review
column to C<--no-watch> and C<checklist-unmoved> reported nine cards in it
within minutes.

The columns a card rule leaves alone are answered in one place: resting in the
backlog, finished in an ending, or in a column nobody is watching.

=cut
