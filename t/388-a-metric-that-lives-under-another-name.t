#!/usr/bin/env perl
# TKT-410. card-metrics --require checks a record's fields with a raw
# $record->{$_} lookup. scope_in and scope_out are never flat record fields
# on ANY record type - ticket or epic - only nested under scope.included and
# scope.excluded. Measured live: a TICKET with scope_in/scope_out explicitly
# set via --scope-in/--scope-out still tripped card-metrics --require
# scope_in,scope_out, exactly like the epic case the ticket describes. The
# reporter's belief it resolved cleanly on tickets was a mix-up with a
# different, unrelated check (ticket.missing / _policy_missing_detail, which
# already reads the nested scope object correctly) - card-metrics itself
# never did, on any type.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T17:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Metrics', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'MES', epic_prefix => 'MEE', ticket_prefix => 'MET',
);
my $store = File::Spec->catdir( $tmp, 'police-store' );

$tira->policy_add( project => $root, rule => 'card-metrics',
    enter => 'implement', require => 'scope_in,scope_out', action => 'log-only' );

sub reported {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq 'card-metrics' } @{ $pass->{violations} } ];
}

# --- a TICKET with scope set is satisfied, not permanently unsatisfiable ----
my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Scoped ticket' );
$tira->record_update( author => 'claude', project => $root, ref => $ticket->{ref},
    scope_in => ['what is included'], scope_out => ['what is excluded'] );
$tira->record_move( author => 'claude', project => $root, ref => $ticket->{ref}, column => 'implement' );

my @ticket_found = grep { $_->{ref} eq $ticket->{ref} } @{ reported() };
is( scalar @ticket_found, 0,
    'a ticket whose scope.included and scope.excluded are both populated satisfies scope_in,scope_out' );

# --- an EPIC with scope set is satisfied too - the case the ticket names ----
my $epic = $tira->create_record( project => $root, type => 'epic', title => 'Scoped epic' );
$tira->record_update( author => 'claude', project => $root, ref => $epic->{ref},
    scope_in => ['what is included'], scope_out => ['what is excluded'] );
$tira->record_move( author => 'claude', project => $root, ref => $epic->{ref}, column => 'implement' );

my @epic_found = grep { $_->{ref} eq $epic->{ref} } @{ reported() };
is( scalar @epic_found, 0,
    'an epic whose scope.included and scope.excluded are both populated satisfies scope_in,scope_out' );

# --- genuinely missing scope still reports, on either type ------------------
my $unscoped = $tira->create_record( project => $root, type => 'ticket', title => 'Unscoped' );
$tira->record_move( author => 'claude', project => $root, ref => $unscoped->{ref}, column => 'implement' );

my @unscoped_found = grep { $_->{ref} eq $unscoped->{ref} } @{ reported() };
is( scalar @unscoped_found, 1, 'a card with no scope recorded still reports - the check still works' );
like( $unscoped_found[0]{detail}, qr/scope_in/,  'names scope_in as missing' );
like( $unscoped_found[0]{detail}, qr/scope_out/, 'names scope_out as missing' );

done_testing;

__END__

=head1 NAME

388-a-metric-that-lives-under-another-name.t - card-metrics resolves scope_in/scope_out against nested scope

=head1 DESCRIPTION

TKT-410: card-metrics --require checked scope_in/scope_out with the same
raw C<$record-E<gt>{$_}> lookup it uses for every other field, but those two
never exist as flat fields on any record type - only nested under
C<scope.included>/C<scope.excluded>. The rule now special-cases those two
names to read the nested object, the same lookup C<_policy_missing_detail>
already used, so the requirement is satisfiable on tickets and epics alike
while every other C<--require> field keeps its existing flat lookup.

=cut
