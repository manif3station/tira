#!/usr/bin/env perl
# TKT-1167. record_list(sum=>FIELD, refs_only=>1) returned only a bare
# arrayref of refs - the sum computed during the same walk was silently
# discarded, because the refs_only-return fires before the sum-return.
# Same root cause and sibling of TKT-1166's --sum+--count fix, but for
# --refs-only instead.
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
my $tira  = Tira->new;
my $root  = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Sum refs-only', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'SRS', epic_prefix => 'SRE', ticket_prefix => 'SRT',
);
$tira->project_update( project => $root, numeric_field => 'points' );

my $a = $tira->create_record( project => $root, type => 'ticket', title => 'Five points', points => 5 );
my $b = $tira->create_record( project => $root, type => 'ticket', title => 'Seven points', points => 7 );

# --- sum + refs_only together must not silently drop the sum -------------

my $result = eval {
    $tira->record_list( project => $root, type => 'ticket', sum => 'points', refs_only => 1 );
};

my $err = $@;
ok( $err, 'sum+refs_only is refused rather than silently dropping one or the other' )
  or diag( 'got: ' . ( ref $result ) . ' - ' . ( ref $result eq 'ARRAY' ? "[@$result]" : 'n/a' ) );
like( $err, qr/--sum/, 'the refusal names --sum' );
like( $err, qr/--refs-only|refs_only/, 'the refusal names --refs-only' );

done_testing;

__END__

=head1 NAME

1170-a-refs-list-that-dropped-its-own-total.t - --sum silently vanished when --refs-only was also given

=head1 DESCRIPTION

TKT-1167. C<record_list(sum =E<gt> FIELD, refs_only =E<gt> 1)> returned a
bare arrayref of refs with no sum information at all - the refs_only-return
in C<lib/Tira.pm> fires before the sum-return, so the sum computed during
the same walk was silently discarded. Sibling of TKT-1166's C<--sum>+C<--count>
fix, same root cause, different flag.

=cut
