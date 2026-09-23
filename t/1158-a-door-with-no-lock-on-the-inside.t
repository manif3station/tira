#!/usr/bin/env perl
# TKT-1144. The required-action gate lives only in the CLI dispatch layer
# (Tira::CLI.pm's run(), which calls _column_required_action_violation
# before $tira->record_move) - the engine's own record_move has no such
# check built in. Any caller reaching record_move a different way skips
# the gate entirely, with no exemption and no reason recorded.
#
# TKT-457 already closed the identical gap for the AUTHOR requirement
# (record_move now refuses an unattributed caller) and its own comment
# says the required-action check "lives only in the CLI dispatch layer"
# as an acknowledged, still-open fact. This card closes the other half.
#
# Confirmed live on a real board: a card moved through 5+ columns, each
# time leaving that column's own required items pending and never
# exempted, authored by an automation identity - not the browser
# dashboard, which is the ONLY path this exemption is meant for (TKT-426,
# owner: "a human on the dashboard is not an agent skipping a gate" /
# "Human on html dashboard do not have this restriction. Only on cli
# commands" / "If skipping only thru exemption with reason ... without
# that but able to skip required action items is a bug").
#
# WRITTEN RED.

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
    name => 'Gated', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'implement', 'done' ],
    sow_prefix => 'DLS', epic_prefix => 'DLE', ticket_prefix => 'DLT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Locked door', author => 'claude' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );

# Column-template auto-population (_apply_column_required_actions) is a
# CLI-dispatch-layer step, run AFTER record_move returns - it is bookkeeping,
# not part of this bug. Added directly here instead, so this fixture does not
# quietly depend on the very layer this card is testing the absence of.
$tira->required_item_add(
    project => $root, ref => $card->{ref}, author => 'claude',
    item => 'write a red test', status => 'pending', column => 'implement',
);

my ($item) = grep { ( $_->{column} // '' ) eq 'implement' }
  @{ $tira->record_show( project => $root, ref => $card->{ref} )->{required_items} };
ok( $item, 'the card carries a pending required item tagged to the column it is in' );
is( $item->{status}, 'pending', 'and it is genuinely unmet, not already done' );

# --- THE BUG: a direct engine call skips the gate the CLI enforces ----------

{
    my $result = eval {
        $tira->record_move( project => $root, ref => $card->{ref}, column => 'done', author => 'claude' );
    };
    my $error = $@;
    ok( !$result, 'a direct record_move call refuses to leave a column with an unmet required item' )
      or diag('record_move silently succeeded - the exact gap this card exists to close');
    like( $error, qr/write a red test/, 'and the refusal names the unmet item, the same as the CLI\'s own refusal' );

    my $after = $tira->record_show( project => $root, ref => $card->{ref} );
    is( $after->{column}, 'implement', 'and the card genuinely did not move' );
}

# --- Codex review: a caller-supplied flag must not be the bypass -----------
#
# The first version of this fix trusted a plain %args key
# (_dashboard_move), set only by Tira::CLI::Browser's own two call sites by
# convention - but nothing stopped any OTHER caller from setting the
# identical key itself. That would have reopened the exact hole this card
# exists to close, just one argument later. record_move now decides via
# caller() - which package's own source is actually making the call - not
# by anything the caller hands it, so a caller in this test's own package
# cannot manufacture the exemption no matter what it passes.

{
    my $result = eval {
        $tira->record_move( project => $root, ref => $card->{ref}, column => 'done', author => 'claude', _dashboard_move => 1 );
    };
    ok( !$result, 'passing _dashboard_move => 1 from outside Tira::CLI::Browser does not bypass the gate' )
      or diag('record_move trusted a caller-supplied flag - the exact hole Codex review caught');
    like( $@, qr/write a red test/, 'and the refusal is the genuine one, not silently swallowed' );

    my $after = $tira->record_show( project => $root, ref => $card->{ref} );
    is( $after->{column}, 'implement', 'and the card still genuinely did not move' );
}

# --- the CLI dispatch path gives the identical refusal, unchanged ----------

{
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME}   = $root;
        local $ENV{TIRA_AUTHOR} = 'claude';
        Tira::CLI->run( command => 'record.move', tira => $tira,
            argv => [ '--type', 'ticket', '--ref', $card->{ref}, '--column', 'done', '-o', 'json' ] );
    };
    isnt( $status, 0, 'the CLI dispatch path still refuses the identical move' );
    like( $err, qr/write a red test/, 'with the same unmet item named' );
}

# --- exempted items are still the sanctioned way through --------------------

{
    $tira->record_update(
        project => $root, ref => $card->{ref}, author => 'claude',
        required_exempt => ['write a red test'], exempt_reason => ['covered by an integration test instead'],
    );
    my $result = eval {
        $tira->record_move( project => $root, ref => $card->{ref}, column => 'done', author => 'claude' );
    };
    ok( $result, 'an item exempted with --exempt-required/--exempt-reason still lets the move through' )
      or diag($@);
    is( $result->{column}, 'done', 'and the card actually moved this time' );
}

# --- exemption by the item's own REQ id works too, not only its text -------
#
# Codex review: the subtest above only exempts by the item's TEXT. TKT-1084
# established that exempting by a required item's own id (the board-visible
# identifier every police finding already names it by, not only its
# descriptive text) is a separate, equally-sanctioned path - _item_is_exempt
# checks the id first. Direct-caller coverage should prove both.

{
    my $card3 = $tira->create_record( project => $root, type => 'ticket', title => 'Exempted by id, directly', author => 'claude' );
    $tira->record_move( project => $root, ref => $card3->{ref}, column => 'implement', author => 'claude' );
    my $item3 = $tira->required_item_add(
        project => $root, ref => $card3->{ref}, author => 'claude',
        item => 'confirm the id path too', status => 'pending', column => 'implement',
    );
    $tira->record_update(
        project => $root, ref => $card3->{ref}, author => 'claude',
        required_exempt => [ $item3->{id} ], exempt_reason => ['exempted by its own REQ id directly'],
    );
    my $result = eval {
        $tira->record_move( project => $root, ref => $card3->{ref}, column => 'done', author => 'claude' );
    };
    ok( $result, 'an item exempted by its own REQ id (not only its text) also lets a direct record_move call through' )
      or diag($@);
    is( $result->{column}, 'done', 'and this card actually moved too' );
}

# --- a backward move is unaffected - it still bypasses and resets ----------

{
    my $card2 = $tira->create_record( project => $root, type => 'ticket', title => 'Goes back', author => 'claude' );
    $tira->record_move( project => $root, ref => $card2->{ref}, column => 'implement', author => 'claude' );
    $tira->required_item_add(
        project => $root, ref => $card2->{ref}, author => 'claude',
        item => 'this is still pending', status => 'pending', column => 'implement',
    );
    my $result = eval {
        $tira->record_move( project => $root, ref => $card2->{ref}, column => 'backlog', author => 'claude' );
    };
    ok( $result, 'a backward move is not blocked by a genuinely unmet item in the column being left' ) or diag($@);
}

done_testing;

__END__

=head1 NAME

1158-a-door-with-no-lock-on-the-inside.t - record_move refuses an unmet
required item for every caller, not only the CLI

=head1 DESCRIPTION

TKT-1144. C<Tira::CLI.pm>'s C<run()> checks C<_column_required_action_violation>
before calling C<record_move>, but the engine method itself has no such
check - so any caller reaching it a different way (confirmed live: an
automation identity moved a real card through five columns, each time
leaving that column's own required items pending and unexempted) skips the
gate entirely. C<record_move> now refuses by default, the same way the CLI's
own pre-check already does; C<--exempt-required>/C<--exempt-reason> remains
the only sanctioned way through. The browser dashboard's own TKT-426
exemption (a human on the dashboard is not an agent skipping a gate) is
preserved separately, at its own call sites, not tested here.

=cut
