#!/usr/bin/env perl
# TKT-659. tira.<type>.show answers with two different shapes depending on
# how many refs it was given: one ref returns the record itself (top-level
# keys like acceptance_criteria, affects_versions, ...); two or more refs
# return {count, order, records}. A caller written against one shape gets
# undef from the other - discovered by writing a caller and watching it
# fail the day a second ref is passed.
#
# TKT-354 already settled this exact question for tira.next, which used to
# answer with a bare array while a busy board answered {next, then} - the
# same command returning two different TYPES depending on state. The fix
# there was one shape for every state. This card follows the same
# resolution: the {count, order, records} envelope for every call to show,
# a single ref being a collection of one.
#
# The fix is scoped to the CLI dispatch layer only (lib/Tira/CLI.pm's
# record.show branch) - record_show itself is untouched, since it is
# reused internally throughout lib/Tira.pm as a fetch-then-mutate
# primitive and its own return shape cannot change without touching every
# one of those ~46 call sites for no reason connected to this card.

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
    name => 'Shapely', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SFS', epic_prefix => 'SFE', ticket_prefix => 'SFT',
);
my $a = $tira->create_record( project => $root, type => 'ticket', title => 'First' );
my $b = $tira->create_record( project => $root, type => 'ticket', title => 'Second' );

sub run {
    my (@argv) = @_;
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    my $old = select $out;
    Tira::CLI->run( command => 'record.show', tira => $tira, argv => \@argv );
    select $old;
    return Tira::json_decode($stdout);
}

my $one = run( '--type', 'ticket', '--ref', $a->{ref}, '-o', 'json' );
my $two = run( '--type', 'ticket', '--ref', $a->{ref}, '--ref', $b->{ref}, '-o', 'json' );

ok( exists $two->{records} && exists $two->{count} && exists $two->{order},
    'two refs answer with the {count, order, records} envelope' );

# The acceptance criterion this card is about: one shape, however many refs.
ok( exists $one->{records} && exists $one->{count} && exists $one->{order},
    'a single ref also carries the {count, order, records} envelope now' );
is( ref $one->{records}, 'HASH', 'records is keyed the same way for one ref as for many' );
is( $one->{records}{ $a->{ref} }{title}, 'First',
    'every field a flat show carried before this fix is still reachable, just nested under records' );
is( $one->{count}, 1, 'a single ref reports count 1' );
is_deeply( $one->{order}, [ $a->{ref} ], 'and its order names just that ref' );

done_testing();

__END__

=head1 NAME

659-a-shape-that-depends-on-how-many.t - tira.<type>.show should answer
with one envelope shape whatever the ref count

=head1 DESCRIPTION

TKT-659. C<record.show> used to answer with the flat record for exactly
one C<--ref> and C<{count, order, records}> for two or more - the same
asymmetry TKT-354 already fixed once for C<tira.next>. Now every call
answers with the envelope, a single ref being a collection of one, at
the CLI dispatch layer only - C<record_show> itself is unchanged, since
it is reused internally as a fetch-then-mutate primitive throughout
C<lib/Tira.pm>.

=cut
