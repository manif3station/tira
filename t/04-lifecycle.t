#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $clock = 0;
my $tira = Tira->new( clock => sub { sprintf '2026-08-05T00:00:%02d+0100', $clock++ } );
my $root = File::Spec->catdir( $tmp, 'lifecycle' );
$tira->create_project( name => 'Lifecycle', dir => $root );

my $project = $tira->project_show( project => $root );
is( $project->{name}, 'Lifecycle', 'project can be shown' );
$project = $tira->project_update( project => $root, name => 'Renamed' );
is( $project->{name}, 'Renamed', 'project name can be updated' );

my $person = $tira->person_add( project => $root, id => 'ada', name => 'Ada', email => 'ada@example.test' );
is( $person->{id}, 'ada', 'person can be added' );
is( scalar @{ $tira->person_list( project => $root ) }, 1, 'people can be listed' );
$person = $tira->person_update( project => $root, id => 'ada', email => '' );
is( $person->{email}, '', 'person field can be cleared' );

my $custom = $tira->link_type_add( project => $root, outward => 'implements', inward => 'is-implemented-by' );
is( $custom->{outward}, 'implements', 'custom link type can be added' );
ok( @{ $tira->link_type_list( project => $root ) } >= 5, 'link types can be listed' );
$tira->link_type_remove( project => $root, outward => 'implements' );

$tira->column_add( project => $root, type => 'ticket', name => 'in-progress', label => 'In Progress', after => 'backlog' );
$tira->column_add( project => $root, type => 'ticket', name => 'review', before => 'discard' );
is_deeply(
    [ map { $_->{name} } @{ $tira->column_list( project => $root, type => 'ticket' ) } ],
    [qw(backlog in-progress review discard)],
    'columns are inserted in requested order',
);
$tira->column_rename( project => $root, type => 'ticket', name => 'review', new_name => 'verification', label => 'Verification' );
$tira->column_reorder( project => $root, type => 'ticket', name => 'verification', before => 'in-progress' );
is_deeply(
    [ map { $_->{name} } @{ $tira->column_list( project => $root, type => 'ticket' ) } ],
    [qw(backlog verification in-progress discard)],
    'column rename and reorder update configuration',
);

my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Lifecycle ticket' );
is( $tira->record_show( project => $root, ref => $ticket->{ref} )->{title}, 'Lifecycle ticket', 'record can be shown' );
$ticket = $tira->record_update( author => 'ada',
    project => $root, ref => $ticket->{ref}, title => 'Updated',
    acceptance => [ 'Works', 'Is tested' ], assignee => 'ada',
);
is( $ticket->{title}, 'Updated', 'record scalar can be updated' );
is_deeply( $ticket->{acceptance_criteria}, [ 'Works', 'Is tested' ], 'record array can be updated' );

$ticket = $tira->record_move(author => 'ada',  project => $root, ref => $ticket->{ref}, column => 'in-progress' );
is( $ticket->{column}, 'in-progress', 'record can move to a custom column' );
is( scalar @{ $tira->record_list( project => $root, type => 'ticket', column => 'in-progress' ) }, 1, 'record list filters column' );
$tira->record_discard(author => 'ada',  project => $root, ref => $ticket->{ref} );
$ticket = $tira->record_restore(author => 'ada',  project => $root, ref => $ticket->{ref}, column => 'verification' );
is( $ticket->{column}, 'verification', 'discarded record can restore to a chosen column' );

$tira->column_remove( project => $root, type => 'ticket', name => 'verification', author => 'ada', reason => 'no longer needed' );
is( $tira->record_show( project => $root, ref => $ticket->{ref} )->{column}, 'discard', 'removing a column discards its records' );

$tira->board_refs( project => $root, type => 'ticket', prefix => 'DEV', digits => 5 );
my $next = $tira->create_record( project => $root, type => 'ticket', title => 'New prefix' );
is( $next->{ref}, 'DEV-00002', 'new reference configuration preserves monotonic counter' );

my $validation = $tira->project_validate( project => $root );
is_deeply( $validation->{issues}, [], 'valid project reports no issues' );
$tira->person_add( project => $root, id => 'unused', name => 'Unused' );
$tira->person_remove( project => $root, id => 'unused' );
is( scalar @{ $tira->person_list( project => $root ) }, 1, 'unused person can be removed' );

done_testing;

__END__

=head1 NAME

04-lifecycle.t - Tira project, board, record, and people lifecycle behavior

=head1 DESCRIPTION

Exercises the first complete-command slice defined by.

=cut
