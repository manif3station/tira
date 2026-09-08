#!/usr/bin/env perl
# TKT-695. A tasklist item whose refs name a card that does not exist is
# reported by nothing: task-unlinked only checks whether refs is EMPTY,
# and task-card-mismatch silently skips a ref it cannot resolve, on the
# stated assumption task-unlinked covers it. Neither does.
#
# Fixed in task-card-mismatch, since it already resolves every ref
# against the board to do its other two checks and carries no --age
# grace - a dangling ref is wrong the moment it is typed.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'store' );
my $now   = '2026-09-08T16:00:00Z';
my $tira  = Tira->new( clock => sub { $now } );
$tira->project_new(
    name => 'Dangling', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'DNS', epic_prefix => 'DNE', ticket_prefix => 'DNT',
);
$tira->policy_add( project => $root, rule => 'task-card-mismatch', column => 'implement', action => 'log-only' );
$tira->policy_add( project => $root, rule => 'task-unlinked', age => '1s', action => 'log-only' );

sub reported {
    my $pass = $tira->police_pass( project => $root, store => $store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    return $pass->{violations};
}

# --- a mistyped ref is reported, and by task-card-mismatch specifically ------

my $dangling = $tira->tasklist_add( project => $root, text => 'A note about the wrong thing', refs => ['DNT-999'] );
$tira->tasklist_update( project => $root, id => $dangling->{id}, status => 1 );

my @found = grep { $_->{ref} eq $dangling->{id} } @{ reported() };
my @mismatch = grep { $_->{rule} eq 'task-card-mismatch' } @found;
my @unlinked = grep { $_->{rule} eq 'task-unlinked' } @found;

is( scalar @mismatch, 1, 'task-card-mismatch reports the dangling ref' );
like( $mismatch[0]{detail}, qr/DNT-999/, 'and names the ref that resolves to nothing' );
is( scalar @unlinked, 0, 'task-unlinked stays silent - the refs array is not empty' );

# --- an empty refs list is still task-unlinked's business, unchanged --------

my $unlinked_task = $tira->tasklist_add( project => $root, text => 'Never linked to anything' );
$now = '2026-09-08T16:00:02Z';
my @still = grep { $_->{ref} eq $unlinked_task->{id} && $_->{rule} eq 'task-unlinked' } @{ reported() };
is( scalar @still, 1, 'a task with an empty refs list is still task-unlinked, unaffected by this fix' );

# --- a discarded card is not a dangling ref ----------------------------------

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Set aside' );
$tira->record_discard( project => $root, author => 'claude', ref => $card->{ref}, reason => 'not needed' );
my $discarded_task = $tira->tasklist_add( project => $root, text => 'Points at a discarded card', refs => [ $card->{ref} ] );
$tira->tasklist_update( project => $root, id => $discarded_task->{id}, status => 1 );
my @discard_found = grep { $_->{ref} eq $discarded_task->{id} } @{ reported() };
is( scalar( grep { $_->{rule} eq 'task-card-mismatch' && $_->{detail} =~ /not a card/ } @discard_found ), 0,
    'a discarded card still resolves, so it is not reported as dangling' );

done_testing();

__END__

=head1 NAME

695-a-ref-that-names-nothing.t - a dangling task ref is reported by
task-card-mismatch, not silently deferred to task-unlinked

=head1 DESCRIPTION

TKT-695. task-unlinked's own check is emptiness, not resolvability, so a
present-but-mistyped ref read as "linked". task-card-mismatch already
resolves every ref against the board and used to skip an unresolvable
one on the stated assumption task-unlinked covered it - it did not.
task-card-mismatch now reports it directly, since it already holds the
resolution and carries no age grace to wait out.

=cut
