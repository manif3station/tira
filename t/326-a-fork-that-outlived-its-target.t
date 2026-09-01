#!/usr/bin/env perl
# A column's chain (--next) names other columns it may move forward into.
# Neither column_remove nor column_apply scrubbed a removed column's name
# out of another column's stored next array - only the removed column's
# own config entry went away, and its cards moved to discard, but every
# OTHER column still pointing at it kept doing so.
#
# Once a dangling name sits in a column's next, _column_chain_violation
# (lib/Tira/CLI.pm) treats that column as still forking to a column that no
# longer exists: any forward move whose destination is not in the
# (partly nonexistent) fork list is refused, and the refusal's own
# suggested remedy - "move there first" - itself fails, since the named
# column cannot be moved to either. A card sitting in the affected column
# has no valid forward move and no command the refusal offers actually
# works.
#
# Found by the hourly-hunt agent turn (TKT-474) on its first real run.
# TKT-475.

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
    name => 'Fork', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'a', 'b', 'done' ],
    sow_prefix => 'FKS', epic_prefix => 'FKE', ticket_prefix => 'FKT',
);

# --- column_remove scrubs a removed column out of every other column's next --

$tira->column_update( project => $root, type => 'ticket', name => 'a', next => [ 'b', 'done' ], author => 'claude' );
$tira->column_remove( project => $root, type => 'ticket', name => 'b', author => 'claude', reason => 'no longer needed' );
my $after_remove = $tira->column_list( project => $root, type => 'ticket' );
my ($a1) = grep { $_->{name} eq 'a' } @{$after_remove};
is_deeply( $a1->{next}, ['done'], 'removing a column strips it from every other column\'s stored next array' );

# --- column_apply scrubs a dangling next too, even if the caller's own payload still names it --
# (the Columns dialog's Next checkboxes are built once when it opens and
# never refreshed if another row removes the column they point at in the
# same editing session, so a stale selection can reach column_apply.)

my $before = $tira->column_list( project => $root, type => 'ticket' );
my @layout = grep { $_->{name} ne 'done' }
  map { { name => $_->{name}, label => $_->{label}, watched => $_->{watched} ? 1 : 0, next => $_->{next} } }
  @{$before};
# 'a' still names the about-to-be-removed 'done' in its own next, as a stale client payload would.
( grep { $_->{name} eq 'a' } @layout )[0]{next} = ['done'];
$tira->column_apply( project => $root, type => 'ticket', columns => \@layout );
my $after_apply = $tira->column_list( project => $root, type => 'ticket' );
my ($a2) = grep { $_->{name} eq 'a' } @{$after_apply};
is_deeply( $a2->{next}, [], 'column_apply strips a next entry naming a column absent from the saved layout too' );

# --- column_update refuses --next naming a column that does not exist --

my $error = eval {
    $tira->column_update( project => $root, type => 'ticket', name => 'a', next => ['nowhere'], author => 'claude' );
    1;
} ? undef : $@;
like( $error, qr/does not exist/, 'declaring --next for a column that does not exist is refused, not silently accepted' );

done_testing;

__END__

=head1 NAME

326-a-fork-that-outlived-its-target.t - a removed column is scrubbed from every other column's chain

=head1 DESCRIPTION

Removing a column - via C<column_remove> directly or via C<column_apply>
(what the Columns dialog's Save button calls) - now strips that column's
name from every other column's stored C<next> array, and C<column_apply>
also scrubs any C<next> entry naming a column absent from the layout being
saved, even when the caller's own payload still names it (the dialog's Next
checkboxes are a snapshot taken when it opened and are not refreshed by
another row's removal in the same session). C<column_update> refuses
C<--next> naming a column that does not exist outright, rather than
silently accepting a typo. TKT-475.

=cut
