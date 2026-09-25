#!/usr/bin/env perl
# TKT-982. Moving a card SIDEWAYS into a park column (e.g.
# blocked-by-dependency) that the source column itself declares as one of
# its own valid --next fork targets reset required actions for EVERY
# previously-completed column, not just the target's own -
# _apply_column_required_actions (lib/Tira/CLI/Move.pm) decided whether a
# move was "forward" or "backward" purely by comparing array-position
# index, and a park column reachable as a declared sideways fork from
# many working columns typically sits early in that array - making
# $to_idx < $from_idx true even though the move is not a retreat at all.
#
# WRITTEN RED: no fork exemption exists yet, so this reproduces against
# the pre-fix code.
#
# Codex review: a first draft exempted ANY declared fork, forward-
# positioned or not - column_update only checks that a --next target
# exists, not where it sits, so a board naming a genuine EARLIER working
# column as a fork target (for some other legitimate reason) would have
# had a real retreat silently exempted. Narrowed to require the
# destination be genuinely UNWATCHED too, matching the original report's
# own "unwatched park" framing - this file's own "watched fork, still
# resets" case below exists specifically to catch that regression again.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-09-25T00:00:00Z'} );
$tira->project_new(
    name => 'A fork mistaken for a retreat', dir => $root, members => ['claude'],
    columns => ['backlog, blocked-by-dependency, analysing, planning, in-progress, unit-test, done'],
    sow_prefix => 'PFW', epic_prefix => 'PFE', ticket_prefix => 'PFT',
);
$tira->column_update( project => $root, type => 'ticket', name => 'backlog', next => ['analysing'], author => 'claude' );
$tira->column_update( project => $root, type => 'ticket', name => 'blocked-by-dependency', watched => 0, author => 'claude' );
my %chain = ( analysing => 'planning', planning => 'in-progress', 'in-progress' => 'unit-test', 'unit-test' => 'done' );
for my $col ( keys %chain ) {
    $tira->column_update( project => $root, type => 'ticket', name => $col,
        next => [ $chain{$col}, 'blocked-by-dependency' ],
        required_action => [ "Finish work in $col" ], author => 'claude' );
}

sub run_cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => 'record.move', type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

sub complete_up_to_unit_test {
    my ($ref) = @_;
    for my $col (qw(analysing planning in-progress unit-test)) {
        run_cli( '--ref', $ref, '--column', $col, '--author', 'claude', '-o', 'json' );
        my $items = $tira->required_item_list( project => $root, ref => $ref );
        for my $item (@$items) {
            next if $item->{status} eq 'done';
            $tira->required_item_update( project => $root, ref => $ref, author => 'claude',
                id => $item->{id}, status => 'done', command => ['x'], proof => ['x'] );
        }
    }
}

# --- THE BUG: a sideways move into a declared fork target ------------------

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Contended' );
complete_up_to_unit_test( $card->{ref} );

my ( $status, $out, $err ) = run_cli(
    '--ref', $card->{ref}, '--column', 'blocked-by-dependency', '--author', 'claude', '-o', 'json' );
is( $status, 0, 'the sideways move into the declared fork target succeeds' )
  or diag("stderr was: $err");

my $after = $tira->record_show( project => $root, ref => $card->{ref} );
my @pending = grep { $_->{status} ne 'done' } @{ $after->{required_items} };
is( scalar(@pending), 0,
    'every previously-completed required item across analysing/planning/in-progress/unit-test stays done - only the park column has no new items to add' );

# --- MUST NOT REGRESS: a genuine backward retreat still resets, unchanged --

my $card2 = $tira->create_record( project => $root, type => 'ticket', title => 'Contended2' );
complete_up_to_unit_test( $card2->{ref} );
run_cli( '--ref', $card2->{ref}, '--column', 'analysing', '--author', 'claude', '-o', 'json' );
my $after2 = $tira->record_show( project => $root, ref => $card2->{ref} );
my @pending2 = grep { $_->{status} ne 'done' } @{ $after2->{required_items} };
is( scalar(@pending2), 4,
    'a genuine backward retreat (not a declared fork of the source) still resets planning/in-progress/unit-test and repopulates analysing, unaffected by the fork exemption' );

# --- MUST NOT REGRESS: a declared fork to a WATCHED earlier column is not --
# --- exempt either - a board naming a genuine ordinary working column as a -
# --- fork target for some other reason still gets the real retreat reset --
# --- (Codex review caught a first draft that exempted ANY declared fork) --

$tira->column_update( project => $root, type => 'ticket', name => 'unit-test',
    next => [ 'done', 'blocked-by-dependency', 'analysing' ], author => 'claude' );
my $card3 = $tira->create_record( project => $root, type => 'ticket', title => 'Contended3' );
complete_up_to_unit_test( $card3->{ref} );
run_cli( '--ref', $card3->{ref}, '--column', 'analysing', '--author', 'claude', '-o', 'json' );
my $after3 = $tira->record_show( project => $root, ref => $card3->{ref} );
my @pending3 = grep { $_->{status} ne 'done' } @{ $after3->{required_items} };
is( scalar(@pending3), 4,
    'a declared fork to a WATCHED earlier column (analysing, now named in unit-test\'s own next) still resets - only an UNWATCHED park is exempt' );

done_testing();

__END__

=head1 NAME

982-a-fork-mistaken-for-a-retreat.t - a sideways move into a declared
fork target does not reset unrelated columns' required actions

=head1 DESCRIPTION

TKT-982. C<_apply_column_required_actions> decided whether a move was
"forward" (populate the destination's own entry items) or "backward"
(reset every completed required item between source and destination)
purely by comparing the two columns' ARRAY-POSITION index. A park
column such as C<blocked-by-dependency>, declared as a legitimate
C<--next> fork target from several working columns, typically sits
earlier in that array than the columns reaching it - making the
backward branch fire even though the move is not a retreat at all.
Reproduced live: a card with completed required items across four
earlier columns, moved sideways into such a park, had every one of
them reset to pending in a single move. The fix checks whether the
destination is named in the SOURCE column's own declared C<next> fork
list - the same field C<_column_skip_blocked> already reads to decide
whether a FORWARD skip is a legitimate fork - and if so, treats the
move like a forward one. A destination NOT named in the source's own
fork list still resets by the existing index-range logic, unchanged.

=cut
