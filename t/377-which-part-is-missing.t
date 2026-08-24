#!/usr/bin/env perl
# TKT-498. Owner, in Cantonese, watching an agent drop a field: "I want a
# command that shows immediately which parts are missing." card-full-details
# already computed this to fire a violation, but only against a card sitting
# in its declared entry column, and only once police noticed - an agent that
# wanted to know what it had left out had no way to just ask.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Missing', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'MIS', epic_prefix => 'MIE', ticket_prefix => 'MIT',
);
$ENV{TIRA_HOME} = $root;

# --- a bare card, everything absent -----------------------------------------

my $bare = $tira->create_record( project => $root, type => 'ticket', title => 'Bare card', priority => 3 );
my $result = $tira->record_missing( project => $root, type => 'ticket', ref => $bare->{ref} );
is( $result->{ref}, $bare->{ref}, 'names the card it answered for' );
for my $field (qw(description problem_or_feature solution_needed key_details deliverables
    acceptance_criteria test_steps bdd atdd scope_in scope_out checklist parent)) {
    ok( ( grep { $_ eq $field } @{ $result->{missing} } ), "reports $field missing" )
      or diag( 'got: ' . join( ',', @{ $result->{missing} } ) );
}

# --- the same, driven through the CLI dispatch tira.ticket.missing calls ---

my $cli_result = Tira::CLI->run(
    command => 'record.missing', type => 'ticket', tira => $tira,
    argv => [ '--ref', $bare->{ref}, '-o', 'json' ],
);
is( $cli_result, 0, 'the command exits clean' );

# --- a fully-filled card reports nothing missing ----------------------------

my $full = $tira->create_record(
    project => $root, type => 'ticket', title => 'Full card', priority => 2,
    description => 'x', problem_or_feature => 'x', solution_needed => 'x',
);
$tira->record_update(
    project => $root, type => 'ticket', ref => $full->{ref}, author => 'claude',
    key_details => ['x'], deliverables => ['x'], acceptance => ['x'],
    test_steps => ['x'], bdd => ['x'], atdd => ['x'],
    scope_in => ['x'], scope_out => ['x'],
);
$tira->checklist_add( author => 'claude', project => $root, type => 'ticket',
    ref => $full->{ref}, item => 'Step', status => 'Open' );

my $sow = $tira->create_record( project => $root, type => 'sow', title => 'The SOW' );
my $epic = $tira->create_record( project => $root, type => 'epic', title => 'The epic' );
$tira->hierarchy_link( project => $root, parent => $sow->{ref}, child => $epic->{ref} );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $full->{ref} );

my $filled = $tira->record_missing( project => $root, type => 'ticket', ref => $full->{ref} );
is_deeply( $filled->{missing}, [], 'a fully-filled, parented, checklisted card reports nothing missing' );

# --- epic and sow answer through the same command ---------------------------

my $epic_result = $tira->record_missing( project => $root, type => 'epic', ref => $epic->{ref} );
is( $epic_result->{ref}, $epic->{ref}, 'epic.missing answers for an epic too' );

my $sow_result = $tira->record_missing( project => $root, type => 'sow', ref => $sow->{ref} );
is( $sow_result->{ref}, $sow->{ref}, 'and sow.missing for a sow' );

done_testing;

__END__

=head1 NAME

377-which-part-is-missing.t - tira.TYPE.missing answers what card-full-details would flag

=head1 DESCRIPTION

C<record_missing> (reached as C<tira.ticket.missing>/C<tira.epic.missing>/
C<tira.sow.missing>) answers the same question C<card-full-details> already
computes internally to fire a violation - which of the fields a complete
card needs are still empty - without needing the card to sit in its
declared entry column first, and without waiting for police to notice.

=cut
