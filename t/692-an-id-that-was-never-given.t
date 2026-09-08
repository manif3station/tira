#!/usr/bin/env perl
# TKT-692. required_item_update and comment_update interpolate an undef
# ($args{id}/$args{comment}) directly into their "not found" refusal when
# the caller omitted --id/--comment entirely - a warning nobody sees, and a
# message that says the missing thing wasn't found rather than that it was
# never supplied. The same construction is shared by checklist_update and
# _annotate_log (gate.annotate/evidence.annotate), reachable there too even
# though today's other guards happen to catch the common cases first.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-08T15:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Addressed', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ADS', epic_prefix => 'ADE', ticket_prefix => 'ADT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Has entries' );
$tira->required_item_add( project => $root, ref => $card->{ref}, author => 'claude', item => 'First required thing', status => 'pending' );
$tira->required_item_add( project => $root, ref => $card->{ref}, author => 'claude', item => 'Second required thing', status => 'pending' );
$tira->comment_add( project => $root, ref => $card->{ref}, author => 'claude', text => 'A real comment' );

# --- required_item_update with no --id at all --------------------------------

{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $error = eval {
        $tira->required_item_update( project => $root, ref => $card->{ref}, author => 'claude', status => 'pending' );
        1;
    } ? undef : $@;
    ok( $error, 'required_item_update with no --id at all is refused' );
    like( $error, qr/--id\b/, 'and names --id as what is missing' );
    unlike( $error, qr/not found/, 'not misdiagnosed as an id that was not found' );
    is( scalar(@warnings), 0, 'no uninitialized-value warning leaked' );
}

# --- required_item_update with a real but unknown --id: unchanged ------------

{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $error = eval {
        $tira->required_item_update( project => $root, ref => $card->{ref}, author => 'claude', id => 'REQ-999', status => 'pending' );
        1;
    } ? undef : $@;
    ok( $error, 'required_item_update with an unknown --id is still refused' );
    like( $error, qr/not found/, 'still the existing not-found message' );
    like( $error, qr/REQ-001/, 'still lists the valid ids the card has' );
}

# --- comment_update with no --comment at all ----------------------------------

{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $error = eval {
        $tira->comment_update( project => $root, ref => $card->{ref}, author => 'claude', text => 'Edited' );
        1;
    } ? undef : $@;
    ok( $error, 'comment_update with no --comment at all is refused' );
    like( $error, qr/--comment\b/, 'and names --comment as what is missing' );
    unlike( $error, qr/not found/, 'not misdiagnosed as an id that was not found' );
    is( scalar(@warnings), 0, 'no uninitialized-value warning leaked' );
}

# --- comment_update with a real but unknown --comment: unchanged -------------

{
    my $error = eval {
        $tira->comment_update( project => $root, ref => $card->{ref}, author => 'claude', comment => 'CMT-999', text => 'Edited' );
        1;
    } ? undef : $@;
    ok( $error, 'comment_update with an unknown --comment is still refused' );
    like( $error, qr/not found/, 'still the existing not-found message' );
    like( $error, qr/CMT-001/, 'still lists the valid ids the card has' );
}

done_testing();

__END__

=head1 NAME

692-an-id-that-was-never-given.t - a missing id is refused as missing, not
as unknown

=head1 DESCRIPTION

TKT-692. C<required_item_update> and C<comment_update> interpolated an
undef C<$args{id}>/C<$args{comment}> straight into their not-found
refusal, which leaked a warning and told the caller their (nonexistent)
id was not found rather than that one was never supplied. Both now refuse
a missing id directly, naming the flag; an unknown-but-present id still
gets the original not-found message with its list of valid ids.

=cut
