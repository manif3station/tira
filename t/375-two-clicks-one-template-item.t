#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

# Reported directly: "When card being move along on the html dashboard. The
# population of the required action items will be duplicated." TKT-497.
#
# Two near-simultaneous browser moves of the same card - a double-click on the
# status dropdown, or any other double-fire of the same request - both read
# the card's required_items before either has written its addition, both
# decide a column's required-action template item is missing, and both add
# it. Reproduced here with two forked processes racing the same move
# coderef the dashboard actually calls, rather than trusting that a
# sequential test would ever hit the window.

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Dup', dir => $root, columns => [ 'Backlog, Doing, Done' ],
    members => ['claude'],
    sow_prefix => 'DPS', epic_prefix => 'DPE', ticket_prefix => 'DPT',
);
$tira->column_update(
    project => $root, type => 'ticket', name => 'doing',
    required_action => ['Write the code'],
);

my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Work' );

my $payload = { type => 'ticket', ref => $card->{ref}, column => 'doing', _signed_in => 'claude' };

SKIP: {
    skip 'fork unavailable', 2 if !eval { require POSIX; 1 };

    for ( 1, 2 ) {
        my $child = fork();
        skip 'fork unavailable', 2 if !defined $child;
        if ( $child == 0 ) {
            eval { $providers{move}->($payload) };
            POSIX::_exit(0);
        }
    }
    1 while wait() > -1;
}

my $record = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
my @matches = grep { ( $_->{item} // '' ) eq 'Write the code' && ( $_->{column} // '' ) eq 'doing' }
  @{ $record->{required_items} // [] };

is( scalar(@matches), 1,
    'two concurrent browser moves populate the required-action template exactly once, not twice' )
  or diag( 'required_items: ' . join( ', ', map {"$_->{id}:$_->{item}/$_->{column}"} @{ $record->{required_items} // [] } ) );

# A manual add, unaffected: source is not 'required-action' here, so a person
# asking for the same text twice on purpose still gets it - the dedup applies
# only to the auto-populate path.
my $card2 = $tira->create_record( project => $root, type => 'ticket', title => 'Manual' );
$tira->required_item_add(
    project => $root, ref => $card2->{ref}, type => 'ticket', author => 'claude',
    item => 'Write the code', status => 'pending', column => 'doing',
);
$tira->required_item_add(
    project => $root, ref => $card2->{ref}, type => 'ticket', author => 'claude',
    item => 'Write the code', status => 'pending', column => 'doing',
);
my $manual = $tira->record_show( project => $root, type => 'ticket', ref => $card2->{ref} );
is( scalar( @{ $manual->{required_items} // [] } ), 2,
    'a manual required_item_add is not deduplicated - only the auto-populate source is' );

done_testing();

__END__

=head1 NAME

375-two-clicks-one-template-item.t - two concurrent dashboard moves populate a required-action template once, not twice

=head1 DESCRIPTION

Reported directly: "When card being move along on the html dashboard. The
population of the required action items will be duplicated." Two
near-simultaneous browser moves of the same card - a double-click on the
status dropdown, or any other double-fire of the same request - both read
the card's C<required_items> before either has written its addition, both
decide a column's required-action template item is missing, and both add
it. C<required_item_add> now deduplicates C<(column, item)> for its
auto-populate source atomically, inside the same project lock every
concurrent caller serializes through, closing the window. A manual
C<required-action.add> is unaffected - only the template source is
deduplicated.

=cut
