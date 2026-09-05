#!/usr/bin/env perl
# TKT-941. Reported from another project via tira.dev.found.bug_or_improvement:
# "On this project, the ticket board is used exclusively for bank-account
# transactions - every live card is required to carry an amount: key
# detail... The auto-raised card carries no amount:, so it immediately shows
# up as a real problem." TKT-604's own upgrade-gating card always used
# create_record(type => 'ticket'), hardcoded, which fits this board and
# breaks a project that has repurposed its ticket type for something with a
# mandatory invariant of its own.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

sub board_with_upgrade_gate_type {
    my ($type) = @_;
    my $tmp  = tempdir( CLEANUP => 1 );
    my $tira = Tira->new( clock => sub {'2026-09-05T09:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Repurposed', dir => $root, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'RPS', epic_prefix => 'RPE', ticket_prefix => 'RPT',
    );
    $tira->project_update( project => $root, upgrade_gate_type => $type )
      if defined $type;
    $tira->policy_add( project => $root, rule => 'orphan-card', action => 'log-only' );
    return ( $tira, $root );
}

# record_list needs a type, so gather across all three record kinds directly.
sub find_raised_record {
    my ( $tira, $root ) = @_;
    for my $type (qw(sow epic ticket)) {
        my $records = $tira->record_list( project => $root, type => $type );
        my ($found) = grep { ( $_->{title} // '' ) =~ /upgraded/ } @{$records};
        return ( $type, $found ) if $found;
    }
    return;
}

# --- an unconfigured project still gets a ticket, unchanged ----------------

{
    my ( $tira, $root ) = board_with_upgrade_gate_type(undef);
    no warnings 'redefine';
    local $Tira::VERSION = '9.11';
    $tira->police_pass( project => $root, store => File::Spec->catdir( $root, '..', 'police' ), world => {} );
    local $Tira::VERSION = '9.12';
    $tira->police_pass( project => $root, store => File::Spec->catdir( $root, '..', 'police' ), world => {} );
    my ( $type, $record ) = find_raised_record( $tira, $root );
    ok( $record, 'a genuine upgrade still raises a gating card with no configuration' );
    is( $type, 'ticket', 'and it is a ticket, exactly as before this card' );
}

# --- a project that configures epic gets an epic instead --------------------

{
    my ( $tira, $root ) = board_with_upgrade_gate_type('epic');
    no warnings 'redefine';
    local $Tira::VERSION = '9.11';
    $tira->police_pass( project => $root, store => File::Spec->catdir( $root, '..', 'police' ), world => {} );
    local $Tira::VERSION = '9.12';
    $tira->police_pass( project => $root, store => File::Spec->catdir( $root, '..', 'police' ), world => {} );
    my ( $type, $record ) = find_raised_record( $tira, $root );
    ok( $record, 'a project configured for epic still gets a gating card' );
    is( $type, 'epic', 'and it lands on the configured type instead of always ticket' );
}

# --- an invalid configured type is refused at the point of setting it ------

{
    my ( $tira, $root ) = board_with_upgrade_gate_type(undef);
    eval { $tira->project_update( project => $root, upgrade_gate_type => 'discard' ) };
    like( $@, qr/sow, epic, or ticket/i,
        'an invalid upgrade-gate type is refused when set, not when it fails to raise a card later' );
}

done_testing();

__END__

=head1 NAME

562-a-gate-that-only-fits-one-shape-of-board.t - the upgrade-gating card's record type is configurable per project

=head1 DESCRIPTION

TKT-941. C<_raise_upgrade_gate> always called C<create_record> with
C<type =E<gt> 'ticket'>, which fits this board and breaks a project that has
repurposed its own ticket type for something with a mandatory invariant - a
bank-transaction board reported the auto-raised card as a real violation
because it carried no C<amount:>. C<project_update> now accepts
C<upgrade_gate_type> (sow/epic/ticket), and C<_raise_upgrade_gate> reads it,
defaulting to C<ticket> when unset so nothing changes for a board that never
configures it.

=cut
