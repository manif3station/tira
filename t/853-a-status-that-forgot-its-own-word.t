#!/usr/bin/env perl
# tasklist.list prints status as a bare integer, so what the CLI accepts as
# a word comes back as a number.
#
# `d2 tira.tasklist.update --id TSK-428 --status working` is accepted, and
# `d2 tira.tasklist.list` then reports status: 1 - both human and -o json.
# lib/Tira/Tasklist.pm already carries the reverse map
# (@TASKLIST_STATUS_NAME), but only the per-session summary uses it - every
# other reader of tasklist_list gets the raw code, and 1 does not read as
# "working" without opening the module to learn the mapping.
#
# Scope, deliberately: the STORED code is unchanged (TKT-846 owns checklist
# statuses, not this), and tasklist_add/tasklist_update's own returned
# `status` stays the code too - t/390 already establishes that and this card
# does not touch it. Only tasklist_list's own output gains a `status_name`
# field alongside the existing `status` code, so a machine reader keeps its
# stable key and a human reader is not left decoding a number.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Worded', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'WDS', epic_prefix => 'WDE', ticket_prefix => 'WDT',
);

my $pending = $tira->tasklist_add( project => $root, text => 'Read the README' );
my $working = $tira->tasklist_add( project => $root, text => 'Write the fix' );
my $done    = $tira->tasklist_add( project => $root, text => 'Ship it' );

$tira->tasklist_update( id => $working->{id}, project => $root, status => 'working' );
$tira->tasklist_update( id => $done->{id}, project => $root, status => 'done' );

sub named {
    my ($id) = @_;
    my $items = $tira->tasklist_list( project => $root );
    for my $item ( @{$items} ) {
        return $item->{status_name} if $item->{id} eq $id;
    }
    return undef;
}

is( named( $pending->{id} ), 'pending', 'a pending item reads back as the word, not 0' );
is( named( $working->{id} ), 'working', 'a working item reads back as the word, not 1' );
is( named( $done->{id} ),    'done',    'a done item reads back as the word, not 2' );

# --- the stored code is still there, for a caller that wants a stable key --

my $items = $tira->tasklist_list( project => $root );
my ($working_item) = grep { $_->{id} eq $working->{id} } @{$items};
is( $working_item->{status}, 1,
    'THE CODE IS UNCHANGED alongside the new word - tasklist_add/update\'s own '
      . 'returned status stays a code too (t/390), and this is not the same '
      . 'field carrying two vocabularies, it is a second field' );

done_testing();

__END__

=head1 NAME

853-a-status-that-forgot-its-own-word.t - tasklist.list renders status as a word too

=head1 WHY

TKT-853, self-found: a status written as a word ("working") is accepted by
tasklist.update, but tasklist.list answers back with its raw stored code (1)
in both human and JSON output - a reader has to open lib/Tira/Tasklist.pm to
learn what the number means.

=cut
