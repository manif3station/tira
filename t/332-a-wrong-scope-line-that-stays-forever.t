#!/usr/bin/env perl
# scope.included/excluded was the only card list field with no wholesale
# replacement - --scope-in/--scope-out only append, and the six sibling
# fields (key_details, deliverables, acceptance, test_steps, bdd, atdd) all
# had --set-* counterparts. A wrong scope entry, once written, was
# permanent - and scope is the field a reader uses to decide whether a card
# covers what is in front of them. TKT-293.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $tira  = Tira->new( clock => sub {'2026-08-23T05:00:00Z'} );
my $root  = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Scoped', dir => $root, members => ['claude'],
    sow_prefix => 'SCS', epic_prefix => 'SCE', ticket_prefix => 'SCT',
);

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'Wrong scope',
    scope_in => ['probe'], scope_out => ['probe'],
);
is_deeply( $card->{scope}{included}, ['probe'], 'starts with the wrong entry, included' );
is_deeply( $card->{scope}{excluded}, ['probe'], 'starts with the wrong entry, excluded' );

# --- a wholesale replace clears the wrong entry, leaving exactly what was given --

my $replaced = $tira->record_update(
    author => 'claude', project => $root, ref => $card->{ref},
    scope_in_replace => [ 'the real scope' ],
    scope_out_replace => [ 'the real exclusion' ],
);
is_deeply( $replaced->{scope}{included}, ['the real scope'],
    'set-scope-in replaces the list wholesale, wrong entry gone' );
is_deeply( $replaced->{scope}{excluded}, ['the real exclusion'],
    'set-scope-out replaces the list wholesale, wrong entry gone' );

# --- replacing with an empty list clears the field rather than leaving it unchanged --

my $cleared = $tira->record_update(
    author => 'claude', project => $root, ref => $card->{ref},
    scope_in_replace => [], scope_out_replace => [],
);
is_deeply( $cleared->{scope}{included}, [], 'an empty replacement clears included' );
is_deeply( $cleared->{scope}{excluded}, [], 'an empty replacement clears excluded' );

# --- the appending form still appends afterwards, unchanged --

my $appended = $tira->record_update(
    author => 'claude', project => $root, ref => $card->{ref},
    scope_in => ['back again'], scope_out => ['excluded again'],
);
is_deeply( $appended->{scope}{included}, ['back again'], 'scope_in still appends after a replace' );
is_deeply( $appended->{scope}{excluded}, ['excluded again'], 'scope_out still appends after a replace' );

my $appended_twice = $tira->record_update(
    author => 'claude', project => $root, ref => $card->{ref},
    scope_in => ['and again'],
);
is_deeply( $appended_twice->{scope}{included}, [ 'back again', 'and again' ],
    'and appending twice accumulates rather than replacing' );

done_testing;

__END__

=head1 NAME

332-a-wrong-scope-line-that-stays-forever.t - scope.included/excluded gains a wholesale replace

=head1 DESCRIPTION

C<scope.included>/C<scope.excluded> was the only card list field with no
replacement counterpart to its append form - C<--scope-in>/C<--scope-out>
only ever grew the list, so a wrong entry, once written, was permanent.
C<record_update>'s C<scope_in_replace>/C<scope_out_replace>
replace the list wholesale, including with an empty list, the same way the
six sibling C<*_replace> fields already do. TKT-293.

=cut
