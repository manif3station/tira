#!/usr/bin/env perl
# TKT-1166. record_list(sum=>FIELD, count=>1) returned only {count=>N} - the
# sum computed during the same walk was silently discarded, because the
# count-return at lib/Tira.pm:2831 fired before the sum-return at line 2833.
# The CLI's human-output branch (lib/Tira/CLI.pm:898-901) had the identical
# shape: it printed $result->{count} and returned _finish() before the
# sum-printing block ever ran.
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
    name => 'Sum plus count', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SCS', epic_prefix => 'SCE', ticket_prefix => 'SCT',
);
$tira->project_update( project => $root, numeric_field => 'points' );

$tira->create_record( project => $root, type => 'ticket', title => 'Five', numeric_value => 5 );
$tira->create_record( project => $root, type => 'ticket', title => 'Seven', numeric_value => 7 );

# --- the engine: both keys present, neither silently dropped -----------------

my $result = $tira->record_list( project => $root, type => 'ticket', sum => 'points', count => 1 );
is( $result->{count}, 2, 'count is still the number of matching records' );
is( $result->{sum}, 12, 'sum is no longer silently dropped when --count is also given' );

done_testing;

__END__

=head1 NAME

1169-a-total-that-hid-behind-a-count.t - --sum survives being combined with --count

=head1 DESCRIPTION

TKT-1166. C<record_list(sum=>FIELD, count=>1)> returned only C<{count=>N}> -
the sum computed during the same walk was silently discarded, because the
count-return fired before the sum-return ever ran. Fixed by folding C<sum>
into the count-branch's own return when summing, rather than picking one of
the two silently.

=cut
