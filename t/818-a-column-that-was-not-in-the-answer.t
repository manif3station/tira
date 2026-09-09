#!/usr/bin/env perl
# TKT-818, TKT-520 standing bug hunt. t/143 already establishes, deliberately,
# that create_record's own returned hash never carries `column` - it is the
# directory the file sits in, not a stored field, and each caller that needs
# it reads the board back afterward (the CLI dispatch layer,
# Tira::CLI::Records::record_create, already does this for every create).
#
# The browser's own create provider does the same thing, but only when the
# target column is NOT 'backlog' - it calls record_move to get there, and
# record_move's own return DOES carry column, so that path is accidentally
# covered. A card created straight into backlog (the ordinary case) skips
# that call entirely, so the browser's JSON response - and the status
# dropdown that trusts it - never learns which column the card landed in.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS ();
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    project => $root, name => 'Landed', dir => $root,
    members => ['claude'], columns => ['backlog, implement, done'],
    sow_prefix => 'LAS', epic_prefix => 'LAE', ticket_prefix => 'LAT',
);

my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );

# --- THE CARD: created via the browser provider, into backlog --------------

my $created = Cpanel::JSON::XS->new->decode( $providers{create}->(
    { type => 'ticket', title => 'x', column => 'backlog', _signed_in => 'claude' } ) );
ok( $created->{ok}, 'the create route succeeds' );
is( $created->{record}{column}, 'backlog',
    'and the browser\'s own reply names the column the card actually landed in - the '
      . 'status dropdown trusts this JSON directly and must not be told nothing' );

# --- control: a non-backlog column still works, as it already did ----------

my $elsewhere = Cpanel::JSON::XS->new->decode( $providers{create}->(
    { type => 'ticket', title => 'y', column => 'implement', _signed_in => 'claude' } ) );
is( $elsewhere->{record}{column}, 'implement', 'and a non-backlog column is unaffected' );

# --- control: the board agrees -----------------------------------------------

my $shown = $tira->record_show( project => $root, ref => $created->{record}{ref} );
is( $shown->{column}, 'backlog', 'and the board really does have the card in backlog' );

done_testing();

__END__

=head1 NAME

t/818-a-column-that-was-not-in-the-answer.t - the browser create route
always names where the card landed

=head1 DESCRIPTION

TKT-818. The browser's C<create> provider called C<record_move> to reach
the requested column, and only when that column was not C<backlog> - so
the reply for the ordinary case (a plain create, landing in backlog) never
carried C<column> at all, and the dashboard's status dropdown, which
trusts the create reply directly, showed the wrong thing right after
creation.

C<create_record>'s own engine-level return deliberately omits C<column>
(t/143's own control: C<column> is the directory a record's file sits in,
not a stored field) - so the fix is at the browser dispatch layer, reading
the board back the same way C<Tira::CLI::Records::record_create> already
does for every CLI create, rather than changing what the engine promises.

=cut
