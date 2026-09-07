#!/usr/bin/env perl
# TKT-844. Reproduced by the hourly hunt (TKT-520), 2026-09-02, in a
# container: truncate .tira/tasklist.json to '{"broken": ' - the shape a
# half-written file has - and every tasklist reader died with the decoder's
# own words and a lib/ line number:
#
#   malformed JSON string, neither tag, array, object, number, string or
#   atom, at character offset 11 at lib/Tira/Tasklist.pm line 70.
#
# This engine already answers the same class of damage deliberately
# elsewhere: a damaged card is read anyway (t/173), a damaged snapshot
# refuses saying so. The tasklist got neither - only whichever raw message
# the decoder happened to throw, naming a source line in a module the
# caller never called.
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
    name => 'Damaged', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'DMS', epic_prefix => 'DME', ticket_prefix => 'DMT',
);
mkdir File::Spec->catdir( $root, '.git' );

# One real item first, so the file exists and this is a genuine truncation
# rather than an empty-file edge case.
$tira->tasklist_add( project => $root, text => 'a task before the damage' );

my $path = File::Spec->catfile( $root, '.tira', 'tasklist.json' );
open my $fh, '>:raw', $path or die $!;
print {$fh} '{"broken": ';
close $fh;

# --- tasklist.list refuses, naming the file and the damage -------------------

{
    my $error = eval { $tira->tasklist_list( project => $root ); 1 } ? undef : $@;
    ok( defined $error, 'tasklist.list refuses on a damaged tasklist' )
      or diag('tasklist.list did not die at all');

    # non-empty is the whole claim: the assertions below are about what
    # this message says, and an undef $error would fail them for the
    # wrong reason.
    like( $error // '', qr/\S/, 'and the refusal has something to say' );
    like( $error // '', qr/tasklist\.json/, 'it names the damaged file' );
    like( $error // '', qr/damaged/i, 'and says the tasklist is damaged' );
    unlike( $error // '', qr/Tasklist\.pm line \d+/,
        'not the decoder\'s own words naming a lib/ line in a module the caller never called - '
          . 'the exact shape this card exists to end' );
    unlike( $error // '', qr/malformed JSON string/,
        'and not the raw Cpanel::JSON::XS message either' );
}

# --- search --tasklist refuses the same way, since it shares the read -------

{
    my $error = eval { $tira->search( project => $root, tasklist => 1, text => 'task' ); 1 } ? undef : $@;
    ok( defined $error, 'search --tasklist refuses on the same damaged file' )
      or diag('search --tasklist did not die at all');
    like( $error // '', qr/tasklist\.json/, 'and also names the file' );
    unlike( $error // '', qr/Tasklist\.pm line \d+/,
        'and also does not leak a lib/ line number' );
}

# --- police_pass still completes - the scarier version of this bug ----------
#
# His own investigation on the card found this NOT to be true before writing
# the fix, and recorded the disproof rather than assuming the worse case.
# Held here so a fix aimed at the read cannot quietly make the pass fragile.

{
    my $store = File::Spec->catdir( $tmp, 'store' );
    $tira->policy_add( project => $root, rule => 'task-unlinked', action => 'bridge-reminder', age => '10m' );
    my $pass = eval {
        $tira->police_pass( project => $root, store => $store,
            world => { tira => $tira, project => $root } );
    };
    ok( defined $pass, 'police_pass still completes with a corrupt tasklist.json' )
      or diag( "police_pass died: $@" );
}

done_testing();

__END__

=head1 NAME

591-a-tasklist-that-forgot-how-to-read-itself.t - a damaged tasklist refuses, naming itself

=head1 DESCRIPTION

TKT-844. C<Tira::Tasklist::_tasklist_read> used to hand every caller the raw
C<Cpanel::JSON::XS> decoder error and a C<lib/Tira/Tasklist.pm> line number on
a corrupt C<tasklist.json> - naming neither the damaged file nor what was
wrong with it, unlike the deliberate answers this engine already gives a
damaged card or a damaged snapshot.

This holds the fix in place: a decode failure now refuses with a message
naming the tasklist path and saying it is damaged, for every reader that
shares C<_tasklist_read> - C<tasklist.list> and C<search --tasklist> both -
while C<police_pass> keeps completing, since C<task-unlinked> and
C<task-card-mismatch> both walk the list too.

=cut
