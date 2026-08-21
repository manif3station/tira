#!/usr/bin/env perl
# column_apply - what the browser dashboard's Columns dialog Save button
# calls - already reads a column's chain and required-action template back
# (_column_defaults has carried next/required_actions since column_apply
# shipped), but never wrote either one. A layout round-tripped through the
# dialog would silently drop both: open it, change nothing about the chain
# or template, hit Save, and they vanish - the same "accepted, dropped,
# read back as if nothing happened" shape as the options %OPTION_READ_BY
# exists to catch on the CLI side, just never closed on this path.
#
# Found investigating TKT-454 (owner's screenshot: the dialog has no
# fields for either), but the gap is one layer deeper than the missing UI
# - even a caller that DID pass next/required_actions through column_apply
# directly would lose them today.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Layout', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'doc', 'done' ],
    sow_prefix => 'LYS', epic_prefix => 'LYE', ticket_prefix => 'LYT',
);

my $before = $tira->column_list( project => $root, type => 'ticket' );
my @layout = map {
    { name => $_->{name}, label => $_->{label}, watched => $_->{watched} ? 1 : 0,
      ( defined $_->{notify_after} ? ( notify_after => $_->{notify_after} ) : () ),
      next => $_->{next}, required_actions => $_->{required_actions} }
} @{$before};

# --- a layout entry carrying next/required_actions is persisted, not dropped --

( grep { $_->{name} eq 'planning' } @layout )[0]{next} = ['doc'];
( grep { $_->{name} eq 'planning' } @layout )[0]{required_actions} = ['left a note'];

$tira->column_apply( project => $root, type => 'ticket', columns => \@layout );
my $after = $tira->column_list( project => $root, type => 'ticket' );
my ($planning) = grep { $_->{name} eq 'planning' } @{$after};
is_deeply( $planning->{next}, ['doc'], 'next survives a column_apply round-trip' );
is_deeply( $planning->{required_actions}, ['left a note'],
    'required_actions survives a column_apply round-trip too' );

# --- and a second apply, touching nothing about them, does not silently lose them --

my @second = map {
    { name => $_->{name}, label => $_->{label}, watched => $_->{watched} ? 1 : 0,
      ( defined $_->{notify_after} ? ( notify_after => $_->{notify_after} ) : () ),
      next => $_->{next}, required_actions => $_->{required_actions} }
} @{$after};
$tira->column_apply( project => $root, type => 'ticket', columns => \@second );
my $again = $tira->column_list( project => $root, type => 'ticket' );
my ($planning2) = grep { $_->{name} eq 'planning' } @{$again};
is_deeply( $planning2->{next}, ['doc'], 'and a second apply that changes nothing about it keeps next' );
is_deeply( $planning2->{required_actions}, ['left a note'],
    'and keeps required_actions too - a save is not a silent reset' );

done_testing;

__END__

=head1 NAME

319-a-layout-that-forgot-the-chain.t - column_apply persists a column's chain and required-action template

=head1 DESCRIPTION

C<column_apply> - the engine call behind the browser dashboard's Columns
dialog Save button - already read a column's C<next> (chain) and
C<required_actions> (template) back via C<_column_defaults>, but never
wrote either: a layout that round-tripped through it silently dropped
both, the same "accepted, dropped, read back as if nothing happened"
shape %OPTION_READ_BY exists to catch on the CLI side. TKT-454.

=cut
