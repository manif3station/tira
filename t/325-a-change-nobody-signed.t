#!/usr/bin/env perl
# A work log that knows what happened and never who is most of what a work
# log is for.
#
# record_move already refuses a caller with no author (TKT-457) - a move
# with nobody attached to it let a card cross the chain and required-action
# checks unrecorded. Every other write that reaches this file's own journal
# deserves the same guarantee. Caught live on TKT-432: an entire session's
# worth of ticket.update/required-action.update/checklist.update/
# release.record calls landed attributed to nobody, because --author was
# easy to forget on those four command families and nothing refused it.
# Owner's own words, once shown the anonymous work log: "isn't the real fix
# to make them fail?"

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-22T00:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Anonymous', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, done'],
    sow_prefix => 'ANS', epic_prefix => 'ANE', ticket_prefix => 'ANT',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'A card' );

# --- record_update refuses a caller with no author -------------------------------

{
    my $error = eval {
        $tira->record_update( project => $root, type => 'ticket', ref => $card->{ref}, priority => 3 );
        1;
    } ? '' : $@;
    like( $error, qr/say who is making it/, 'record_update refuses with no author' );
    my $unchanged = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    is( $unchanged->{priority}, undef, 'and the write did not happen either' );

    ok( eval {
        $tira->record_update( project => $root, type => 'ticket', ref => $card->{ref}, author => 'claude', priority => 3 );
        1;
    }, 'and succeeds exactly as before once an author is given' );
}

# --- comment_update refuses a caller with no author -------------------------------

{
    my $comment = $tira->comment_add( project => $root, type => 'ticket', ref => $card->{ref},
        author => 'claude', text => 'Original' );
    my $error = eval {
        $tira->comment_update( project => $root, type => 'ticket', ref => $card->{ref},
            comment => $comment->{id}, text => 'Edited' );
        1;
    } ? '' : $@;
    like( $error, qr/say who is making it/, 'comment_update refuses with no author' );
    ok( eval {
        $tira->comment_update( project => $root, type => 'ticket', ref => $card->{ref},
            comment => $comment->{id}, author => 'claude', text => 'Edited' );
        1;
    }, 'and succeeds exactly as before once an author is given' );
}

# --- checklist_add / checklist_update refuse a caller with no author --------------

{
    my $error = eval {
        $tira->checklist_add( project => $root, type => 'ticket', ref => $card->{ref}, item => 'x', status => 'pending' );
        1;
    } ? '' : $@;
    like( $error, qr/say who is making it/, 'checklist_add refuses with no author' );

    my $entry = $tira->checklist_add( project => $root, type => 'ticket', ref => $card->{ref},
        author => 'claude', item => 'x', status => 'pending' );

    $error = eval {
        $tira->checklist_update( project => $root, type => 'ticket', ref => $card->{ref}, id => $entry->{id}, status => 'in-progress' );
        1;
    } ? '' : $@;
    like( $error, qr/say who is making it/, 'checklist_update refuses with no author' );
    ok( eval {
        $tira->checklist_update( project => $root, type => 'ticket', ref => $card->{ref},
            id => $entry->{id}, author => 'claude', status => 'pending' );
        1;
    }, 'and succeeds exactly as before once an author is given' );
}

# --- required_item_add / required_item_update refuse a caller with no author -----

{
    my $error = eval {
        $tira->required_item_add( project => $root, type => 'ticket', ref => $card->{ref}, item => 'x', status => 'pending' );
        1;
    } ? '' : $@;
    like( $error, qr/say who is making it/, 'required_item_add refuses with no author' );

    my $entry = $tira->required_item_add( project => $root, type => 'ticket', ref => $card->{ref},
        author => 'claude', item => 'x', status => 'pending' );

    $error = eval {
        $tira->required_item_update( project => $root, type => 'ticket', ref => $card->{ref}, id => $entry->{id}, status => 'pending' );
        1;
    } ? '' : $@;
    like( $error, qr/say who is making it/, 'required_item_update refuses with no author' );
    ok( eval {
        $tira->required_item_update( project => $root, type => 'ticket', ref => $card->{ref},
            id => $entry->{id}, author => 'claude', status => 'pending' );
        1;
    }, 'and succeeds exactly as before once an author is given' );
}

# --- gate_add / evidence_add / release_record refuse a caller with no author -----

{
    my $error = eval {
        $tira->gate_add( project => $root, type => 'ticket', ref => $card->{ref}, gate => 'verify', result => 'pass', details => 'x' );
        1;
    } ? '' : $@;
    like( $error, qr/say who is making it/, 'gate_add refuses with no author' );

    $error = eval {
        $tira->evidence_add( project => $root, type => 'ticket', ref => $card->{ref}, summary => 'x' );
        1;
    } ? '' : $@;
    like( $error, qr/say who is making it/, 'evidence_add refuses with no author' );

    $error = eval {
        $tira->release_record( project => $root, type => 'ticket', ref => $card->{ref},
            gate => 'verify', result => 'pass', details => 'x', evidence => 'y', fix_version => '1.0' );
        1;
    } ? '' : $@;
    like( $error, qr/say who is making it/, 'release_record refuses with no author, being built from gate_add' );

    ok( eval {
        $tira->release_record( project => $root, type => 'ticket', ref => $card->{ref}, author => 'claude',
            gate => 'verify', result => 'pass', details => 'x', evidence => 'y', fix_version => '1.0' );
        1;
    }, 'and succeeds exactly as before once an author is given' );
}

done_testing;

__END__

=head1 NAME

325-a-change-nobody-signed.t - every mutating command with a journal entry refuses an anonymous caller

=head1 DESCRIPTION

record_move refuses a caller with no author (TKT-457). record_update,
comment_update, checklist_add/update, required_item_add/update, gate_add,
and evidence_add (and so release_record, built from the latter two plus
record_update) did not - they silently wrote a journal or history entry
attributed to nobody. TKT-466, caught live on TKT-432 after a whole
session's worth of such calls landed anonymous. Each now refuses with the
same message record_move already uses, and each still works exactly as
before once an author is given, whether passed explicitly or resolved from
TIRA_AUTHOR by the CLI layer.

=cut
