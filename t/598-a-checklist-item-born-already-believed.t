#!/usr/bin/env perl
# TKT-958. checklist_update refuses a --status done call with no
# --command/--proof pair (TKT-628), routed through _proof_entries_for.
# checklist_add never called it: a checklist item could be CREATED already
# done, with no evidence at all, bypassing the exact requirement its own
# sibling verb enforces on every later write to the same field.
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
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-09-07T09:00:00Z'} );
$tira->project_new(
    name => 'Born Believed', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'BBS', epic_prefix => 'BBE', ticket_prefix => 'BBT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'A card' );

# --- creating a done item with no pair is refused, same shape as update ----

my $error = eval {
    $tira->checklist_add( author => 'claude', project => $root, ref => $card->{ref},
        item => 'Claimed done on arrival', status => 'done' );
    1;
} ? undef : $@;
ok( defined $error, 'checklist_add refuses --status done with no --command/--proof' )
  or diag('checklist_add accepted a done item with no evidence at all');
like( $error // '', qr/requires at least one --command\/--proof pair/,
    'with the same message checklist_update already gives for the identical gap' );

# --- pending or To Do still need no pair -------------------------------------

my $pending = eval {
    $tira->checklist_add( author => 'claude', project => $root, ref => $card->{ref},
        item => 'Still pending', status => 'pending' );
};
ok( $pending, 'creating an item as pending still needs no pair' ) or diag($@);

my $todo = eval {
    $tira->checklist_add( author => 'claude', project => $root, ref => $card->{ref},
        item => 'Still to do', status => 'To Do' );
};
ok( $todo, 'and as To Do' ) or diag($@);

# --- and done WITH a pair still works, carrying the evidence -----------------

my $done = eval {
    $tira->checklist_add( author => 'claude', project => $root, ref => $card->{ref},
        item => 'Done with real evidence', status => 'done',
        command => ['prove -l t/01.t'], proof => ['ok'] );
};
ok( $done, 'creating an item already done WITH a command/proof pair still works' ) or diag($@);
is( $done->{proof}[0]{command}, 'prove -l t/01.t', 'and the pair is stored on the new entry' );

done_testing();

__END__

=head1 NAME

598-a-checklist-item-born-already-believed.t - checklist_add needs a pair too

=head1 DESCRIPTION

TKT-958. C<checklist_update> refuses a done status with no C<--command>/
C<--proof> pair (TKT-628), through C<_proof_entries_for>. C<checklist_add>
never called that helper, so an item could be created already done with no
evidence at all - creating an item done was a bypass of the exact rule
updating one to done already enforced. C<checklist_add> now calls the same
helper before creating the entry, refusing with the identical message;
pending and To Do items are unaffected, and a done item created WITH a pair
still works, carrying the evidence on the new entry.

=cut
