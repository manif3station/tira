#!/usr/bin/env perl
# TKT-804. required-action.list --ref REF --status pending accepts
# --status (a globally-parsed CLI option) but required_item_list did
# nothing with it - it always returned every required item on the card
# regardless of status, identical in shape to TKT-802/803's
# tasklist.list --ref bug filed earlier this session. A caller citing
# required-action.list --status pending as evidence of what remained
# got an answer that silently included items already done, wrong and
# staying wrong with nothing to signal it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-01T11:00:00+0100' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Statused', dir => $root, members => ['ada'],
    columns => ['backlog, doing, done'],
    sow_prefix => 'STS', epic_prefix => 'STE', ticket_prefix => 'STT',
);

my $card = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'A card' );
$tira->required_item_add(
    project => $root, ref => $card->{ref}, item => 'Do the pending thing', status => 'pending', author => 'ada' );
my $done_item = $tira->required_item_add(
    project => $root, ref => $card->{ref}, item => 'Do the done thing', status => 'pending', author => 'ada' );
$tira->required_item_update(
    project => $root, ref => $card->{ref}, id => $done_item->{id}, status => 'done',
    command => ['ran it'], proof => ['ran it and it worked'], author => 'ada',
);

my $all = $tira->required_item_list( project => $root, ref => $card->{ref} );
is( scalar @{$all}, 2, 'with no --status, both items come back - unchanged behavior' );

my $pending_only = $tira->required_item_list( project => $root, ref => $card->{ref}, status => 'pending' );
is( scalar @{$pending_only}, 1, '--status pending filters to only the pending item - the fix' );
is( $pending_only->[0]{item}, 'Do the pending thing', 'the right one' );

my $done_only = $tira->required_item_list( project => $root, ref => $card->{ref}, status => 'done' );
is( scalar @{$done_only}, 1, '--status done filters to only the done item' );
is( $done_only->[0]{item}, 'Do the done thing', 'the right one' );

eval { $tira->required_item_list( project => $root, ref => $card->{ref}, status => 'nonsense' ) };
like( $@, qr/pending|done/i, 'an unrecognized status is refused by name, not silently matching nothing' );

eval { $tira->required_item_list( project => $root, ref => $card->{ref}, status => '' ) };
like( $@, qr/pending|done/i,
    'an explicit empty --status is refused too, not treated as absent - found in Codex review, TKT-804' );

done_testing;

__END__

=head1 NAME

t/472-a-status-flag-with-no-effect.t - required-action.list's --status
actually filters instead of being silently accepted and ignored

=head1 DESCRIPTION

C<required_item_list> read only C<ref> (and C<blocking>) - never
C<status>. Because C<--status> is a normal option name on other Tira
commands (C<tasklist.update>, C<tasklist.list> since TKT-545), the
generic CLI parser accepted it on C<required-action.list> without
complaint, and the filter it implied silently never happened: every
required item on the card came back regardless of status.

Fixed by filtering on status the same way C<tasklist_list> does,
refusing an unrecognized value rather than matching nothing. TKT-804,
found immediately after TKT-802/803 revealed the identical bug class
on C<tasklist.list>'s C<--ref>.

=cut
