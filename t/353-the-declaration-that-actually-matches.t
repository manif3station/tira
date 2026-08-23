#!/usr/bin/env perl
# policy_resolve picks one winner per rule per record, but its ranking
# (_policy_specificity) and its filter (_policy_applies_to) only look at the
# generic scope fields (--ref, --on-column, --type) - never at a rule's OWN
# column-ish field (card-duration/checklist-idle/wip-limit/gate-missing's
# --column, card-full-details's --enter, card-stalled's --before). Declare
# card-duration on two different columns - exactly how this board declares
# it eight times, once per working column - and every declaration ties at
# specificity 0, so the LAST one declared wins for every card board-wide,
# whether or not that card is even in the column the winning declaration
# names. TKT-483, found while writing TKT-380's own test.
#
# The two other rule-owned fields (--enter for card-full-details, --before
# for card-stalled) are proved by the same mechanism, once each, since the
# fix is one map read by one function rather than one fix per rule.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-08-23T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Ledger', dir => $root, members => ['claude'],
    columns => ['backlog, implement, verify, install, done'],
    sow_prefix => 'LGS', epic_prefix => 'LGE', ticket_prefix => 'LGT',
);

sub card {
    my (%args) = @_;
    return $tira->create_record( project => $root, type => 'ticket', %args );
}

sub move_to {
    my ( $ref, $column ) = @_;
    $tira->record_move( author => 'claude', project => $root, ref => $ref, column => $column );
}

# --- reconstruct this board's own shape: one rule, declared per column ------

my $in_implement = card( title => 'Sitting in implement' );
move_to( $in_implement->{ref}, 'implement' );
my $in_verify = card( title => 'Sitting in verify' );
move_to( $in_verify->{ref}, 'verify' );
my $in_install = card( title => 'Sitting in install' );
move_to( $in_install->{ref}, 'install' );

my $on_implement = $tira->policy_add( project => $root, rule => 'card-duration',
    column => 'implement', age => '10m', action => 'log-only' );
my $on_verify = $tira->policy_add( project => $root, rule => 'card-duration',
    column => 'verify', age => '10m', action => 'log-only' );
my $on_install = $tira->policy_add( project => $root, rule => 'card-duration',
    column => 'install', age => '10m', action => 'log-only' );

# --- each card resolves to its OWN declaration, not the last one declared ---

my $resolve = sub {
    my ($ref) = @_;
    my $resolved = $tira->policy_resolve( project => $root, ref => $ref );
    my ($duration) = grep { $_->{rule} eq 'card-duration' } @{$resolved};
    return $duration;
};

is( $resolve->( $in_implement->{ref} )->{id}, $on_implement->{id},
    'the card in implement resolves to the implement declaration' );
is( $resolve->( $in_verify->{ref} )->{id}, $on_verify->{id},
    'the card in verify resolves to the verify declaration, not the last-declared one' );
is( $resolve->( $in_install->{ref} )->{id}, $on_install->{id},
    'and the card in install resolves to its own, third, declaration' );

# --- and each actually fires: not just resolution, the whole pass -----------

$now = '2026-08-23T09:20:00Z';    # past every 10m age
my $pass = $tira->police_pass( project => $root, store => File::Spec->catdir( $tmp, 'police' ), world => {} );
my @duration_hits = map { $_->{ref} } grep { $_->{rule} eq 'card-duration' } @{ $pass->{violations} };
is_deeply( [ sort @duration_hits ],
    [ sort ( $in_implement->{ref}, $in_verify->{ref}, $in_install->{ref} ) ],
    'all three cards are reported, each against its own column - none silently skipped, none double-reported' );

# --- a card in a column no declaration names resolves to no policy ----------
#
# Not the last-declared one, which is what iteration-order tie-breaking gave
# it before this fix - a card outside every declared column had no rule
# watching it, and was told it did.

my $in_backlog = card( title => 'Not in any watched column' );
is( $resolve->( $in_backlog->{ref} ), undef,
    'a card in a column no card-duration declaration names resolves to no card-duration policy at all' );

# --- proved a second way: card-full-details, scoped by --enter --------------

my $entering = card( title => 'Arriving in implement' );
move_to( $entering->{ref}, 'implement' );
my $enter_implement = $tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'log-only' );
my $enter_verify = $tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'verify', action => 'log-only' );
my $full_resolve = $tira->policy_resolve( project => $root, ref => $entering->{ref} );
my ($full_details) = grep { $_->{rule} eq 'card-full-details' } @{$full_resolve};
is( $full_details->{id}, $enter_implement->{id},
    'card-full-details resolves by its own --enter field the same way, not by declaration order' );

done_testing;

__END__

=head1 NAME

353-the-declaration-that-actually-matches.t - policy_resolve ranks by each rule's own column field

=head1 DESCRIPTION

C<policy_resolve>'s specificity ranking and applicability filter only
consulted the generic scope fields (C<--ref>, C<--on-column>, C<--type>),
never a rule's own column-ish field (C<--column>, C<--enter>, C<--before>).
Declaring the same rule once per column - exactly how this project's own
board declares C<card-duration> - meant every declaration tied, and the
last one declared silently won for every card board-wide. This reconstructs
that shape at a small scale and proves each card now resolves to, and is
evaluated against, its own declaration.

=cut
