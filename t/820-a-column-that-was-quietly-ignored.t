#!/usr/bin/env perl
# TKT-820. Self-discovered while investigating TKT-521's improvement hunt,
# and hit personally earlier this session writing a test fixture:
# `d2 tira.ticket.update --ref REF --column X` is accepted with no error and
# no effect. 'column' is not in @RECORD_UPDATE_FIELDS - deliberately, since
# record_move is the only path that is allowed to change it - but nothing
# refuses the argument when a caller hands it to record_update/ticket.update
# by mistake, so the caller reads a clean exit and an unchanged card as
# confirmation that the move happened.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

my $tira = Tira->new( clock => sub {'2026-09-09T12:00:00Z'} );
$tira->project_new(
    name => 'Columned', dir => $root, members => ['claude'],
    columns    => ['backlog, tests-red, done'],
    sow_prefix => 'CLS', epic_prefix => 'CLE', ticket_prefix => 'CLT',
);

my $created = $tira->create_record(
    project => $root, type => 'ticket', title => 'a card', column => 'backlog',
);
# create_record's own return never carries column - t/143's own control -
# so read it back the way the CLI's own record_create already does.
my $ticket = $tira->record_show( project => $root, ref => $created->{ref} );
is( $ticket->{column}, 'backlog', 'the card starts in backlog' );

# --- record_update refuses a --column argument, rather than silently ignoring it

my $refused = eval {
    $tira->record_update( project => $root, ref => $ticket->{ref}, author => 'claude', column => 'done' );
    1;
};
ok( !$refused, 'record_update with a column argument dies rather than succeeding silently' );
like( $@, qr/column/i, 'and the refusal names the argument that was rejected' );
like( $@, qr/record_move|ticket\.move|record\.move/i,
    'and points at the real move command rather than leaving the caller to guess' );

# --- and the card genuinely did not move ------------------------------------

my $after = $tira->record_show( project => $root, ref => $ticket->{ref} );
is( $after->{column}, 'backlog',
    'the card is still in backlog - the refusal is real, not a die after the write already happened' );

# --- and the refusal is not ticket-specific - record_update is the one
# shared method every record type's own *.update verb calls -------------

for my $type (qw(epic sow)) {
    my $created2 = $tira->create_record(
        project => $root, type => $type, title => "a $type", column => 'backlog',
    );
    my $refused2 = eval {
        $tira->record_update( project => $root, ref => $created2->{ref}, author => 'claude', column => 'done' );
        1;
    };
    ok( !$refused2, "record_update with a column argument dies for a $type record too, not only a ticket" );
}

# --- and an ordinary update, with no column argument, is entirely unaffected

$tira->record_update( project => $root, ref => $ticket->{ref}, author => 'claude', title => 'a renamed card' );
my $renamed = $tira->record_show( project => $root, ref => $ticket->{ref} );
is( $renamed->{title}, 'a renamed card', 'an update naming no column still writes normally' );
is( $renamed->{column}, 'backlog', 'and still has not moved' );

done_testing();

__END__

=head1 NAME

t/820-a-column-that-was-quietly-ignored.t - record_update refuses a --column
argument instead of silently dropping it

=head1 DESCRIPTION

TKT-820. C<column> is deliberately absent from C<@RECORD_UPDATE_FIELDS> -
C<record_move> is the only path allowed to change it - but nothing told a
caller that handed C<record_update> (or C<tira.ticket.update>) a C<--column>
argument that it had done nothing at all. A clean exit and an unchanged card
read as confirmation the move happened, which is worse than an error: a
silent no-op looks identical to success.

C<record_update> now refuses outright when a C<column> argument is present,
naming C<record_move>/the type-specific C<*.move> verb as the real command,
before any part of the update is written - a caller cannot half-succeed and
half-fail this way.

=cut
