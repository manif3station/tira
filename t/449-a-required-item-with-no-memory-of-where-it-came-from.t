#!/usr/bin/env perl
# TKT-652. The entry gate (_column_entry_required_action_violation in
# lib/Tira/CLI.pm) matched a required_items entry against the column's live
# entry template by comparing item TEXT alone. That is right as far as it
# goes - TKT-445/t/422 established that a manual required-action.add item
# satisfies a column's own template exactly like a template-derived one,
# "do the work early" is a real, intentional capability, and this test
# keeps confirming it for entry too, symmetric with exit.
#
# What text-matching alone got wrong: renaming an entry template's wording
# silently un-gated every card already carrying an item under the OLD
# wording, because the stored item's text no longer matched the live
# template and nothing else identified it as an entry obligation. Fixed by
# adding an `entry` marker, stamped on any item genuinely populated from an
# entry template, which the gate now trusts IN ADDITION TO a live text
# match - either is sufficient, so a rename cannot un-gate a marked item,
# and doing the work early still gates entry same as it always gated exit.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-30T11:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Templates', dir => $root, members => ['claude'],
    columns    => [ 'backlog', 'gated', 'next' ],
    sow_prefix => 'TPS', epic_prefix => 'TPE', ticket_prefix => 'TPT',
);
$tira->column_update(
    project => $root, type => 'ticket', name => 'next',
    entry_required_action => ['Confirm the fix is reviewed'],
);

sub run {
    my ( $command, @argv ) = @_;
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME}   = $root;
            local $ENV{TIRA_AUTHOR} = 'claude';
            Tira::CLI->run( command => $command, type => $type, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# --- control: doing the entry work early still gates entry, symmetric with -
# exit's own established "do it early" behaviour (TKT-445/t/422) - a manual
# item worded and columned the same as the entry template, marked done
# ahead of time, satisfies the requirement exactly like exit already does.

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Did the entry work early' );
$tira->record_move( project => $root, ref => $card->{ref}, type => 'ticket', column => 'gated', author => 'claude' );
$tira->required_item_add(
    project => $root, ref => $card->{ref}, type => 'ticket', column => 'next',
    item => 'Confirm the fix is reviewed', status => 'pending', author => 'claude',
);
my ($manual_id) = map { $_->{id} } grep { $_->{item} eq 'Confirm the fix is reviewed' }
  @{ $tira->record_show( project => $root, ref => $card->{ref} )->{required_items} };
$tira->required_item_update(
    project => $root, ref => $card->{ref}, type => 'ticket', id => $manual_id,
    status => 'done', command => ['reviewed ahead of the move'], proof => ['review notes attached'], author => 'claude',
);

my ( $status1, $said1 ) = run( 'ticket.move', '--ref', $card->{ref}, '--column', 'next' );
is( $status1, 0,
    'work done ahead of time under the entry template\'s own wording satisfies the entry requirement - '
      . 'symmetric with how a manual item already satisfies an exit requirement (TKT-445)' );

# --- control: a genuine entry-template item still gates entry normally -----

my $card2 = $tira->create_record( project => $root, type => 'ticket', title => 'Genuinely gated' );
$tira->record_move( project => $root, ref => $card2->{ref}, type => 'ticket', column => 'gated', author => 'claude' );

my ( $status2, $said2 ) = run( 'ticket.move', '--ref', $card2->{ref}, '--column', 'next' );
isnt( $status2, 0, 'a card with no entry item yet still gets one auto-populated and is refused entry, exactly as before' );
like( $said2, qr/Confirm the fix is reviewed/, 'naming the entry requirement' );

# --- the fix: renaming the entry template must not un-gate an item already -
# on a card carrying the old wording - the marker survives a wording
# change, where a text match alone would not.

$tira->column_update(
    project => $root, type => 'ticket', name => 'next',
    entry_required_action => ['Confirm the fix is reviewed, reworded'],
);
my ( $status3, $said3 ) = run( 'ticket.move', '--ref', $card2->{ref}, '--column', 'next' );
isnt( $status3, 0,
    "the card2 item added under the OLD wording still gates entry after the column's entry text changed - "
      . 'if this move now succeeds, the rename silently un-gated a card already carrying the old text' );

# --- control: an exit-template item still carries no entry marker ----------

$tira->column_add( project => $root, type => 'ticket', name => 'checked', after => 'next' );
$tira->column_update(
    project => $root, type => 'ticket', name => 'gated', required_action => ['Prove it works'],
);
my $card3 = $tira->create_record( project => $root, type => 'ticket', title => 'Exit item is not an entry item' );
run( 'ticket.move', '--ref', $card3->{ref}, '--column', 'gated' );
my ($exit_id) = map { $_->{id} } grep { $_->{item} eq 'Prove it works' }
  @{ $tira->record_show( project => $root, ref => $card3->{ref} )->{required_items} };
ok( $exit_id, 'the exit template item was seeded on entry into gated, as it always has been' );

my $exit_item = ( grep { $_->{id} eq $exit_id } @{ $tira->record_show( project => $root, ref => $card3->{ref} )->{required_items} } )[0];
ok( !$exit_item->{entry}, 'and it carries no entry marker - an exit-template item is never mistaken for an entry one' );
ok( $exit_item->{template}, 'but it does carry the template marker, since the exit template itself populated it' );

done_testing();

__END__

=head1 NAME

t/449-a-required-item-with-no-memory-of-where-it-came-from.t - an entry
required item survives its column's wording changing, without losing the
"do the work early" capability that already applied to exit items

=head1 DESCRIPTION

C<_column_entry_required_action_violation> matched required_items entries
against the column's live entry template by TEXT alone. Renaming the
template's wording silently stopped matching every card already carrying
an item under the old text, un-gating them. Fixed by adding an C<entry>
marker, trusted by the gate ALONGSIDE a live text match rather than
instead of it - the marker survives a rename, and the text match keeps
"do the work early" (TKT-445, t/422) working the same way for entry that
it always has for exit. A first version of this fix required the marker
exclusively, which broke that established capability (t/422 went red) by
creating a spurious duplicate for a manually-completed item; corrected
before this card left verify.

=cut
