#!/usr/bin/env perl
# TKT-957, his report: "Auto-raised upgrade-gate card lands in backlog, where
# every column-scoped rule ignores it - so the gate that tracks the upgrade can
# never nag."
#
# HIS PREMISE IS EXACT, and it took three checks rather than one to be sure:
#
#   column-scoped policies name document, done, implement, in-progress,
#   install, pending-push, push, tests-red and verify. Not backlog. So
#   card-duration and checklist-idle never look at it.
#
#   card-still is board-wide and declared here at 4h, which is the obvious
#   objection - and it does not apply either. _resting_columns excludes a
#   column that is protected, terminal or unwatched, and backlog carries
#   protected: 1 as one of Tira's own built-in columns. So card-still rests
#   there too.
#
# Nothing chases a card in backlog. That is not a bug in backlog: a card
# waiting in a queue is not a stalled card, and resting is the correct
# behaviour. It is a gap for the ONE card that is not really waiting - the one
# the gate raised because somebody has to read what changed.
#
# SO THE RULE WATCHES THE CARD, NOT THE COLUMN. Declaring the column-scoped
# rules on backlog would fight a correct decision and speak about every card
# sitting there, which on this board is over a hundred.
#
# THE MARKER. The gate set nothing a rule could match on - no source, no label,
# only a generated title, and matching a title string is the kind of coupling
# that breaks silently when somebody rewords it. It now labels the card it
# raises, which is a durable marker and the field that exists for exactly this.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;
use Tira::CLI::Police;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $now  = '2026-09-06T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Unreviewed', dir => $root, members => ['claude'],
        columns => ['backlog, tests-red, done'],
        sow_prefix => 'UNS', epic_prefix => 'UNE', ticket_prefix => 'UNT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    # Declared through an eval so a missing rule fails each assertion below
    # rather than aborting the file at the fixture - which would leave the
    # source-level check unrun, and that is the one saying whether the red is
    # about the right thing.
    eval {
        $tira->policy_add( project => $root, rule => 'upgrade-unreviewed',
            age => '1h', action => 'bridge-reminder' );
        1;
    };
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ), \$now );
}

sub found {
    my ( $tira, $root, $store ) = @_;
    my $pass = eval {
        $tira->police_pass( project => $root, store => $store,
            world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
    } || {};
    return [ grep { ( $_->{rule} // '' ) eq 'upgrade-unreviewed' }
             @{ $pass->{violations} || [] } ];
}

# --- the rule's shape: an age, and no scope -------------------------------
#
# It watches a card, not a column, so the two options that would scope it to
# one must be refused rather than quietly ignored - a declaration that names a
# column and is then evaluated board-wide reads as working and is not.

{
    my ( $tira, $root ) = board();
    my %rules = map { $_ => 1 } @{ Tira::policy_rules() };
    ok( $rules{'upgrade-unreviewed'}, 'the catalogue offers a rule for an unreviewed upgrade' );

    my $ageless = !eval {
        $tira->policy_add( project => $root, rule => 'upgrade-unreviewed',
            action => 'bridge-reminder' );
        1;
    };
    ok( $ageless, 'it cannot be declared without an age, because "unreviewed" has a length' );

    my $scoped = !eval {
        $tira->policy_add( project => $root, rule => 'upgrade-unreviewed',
            action => 'bridge-reminder', age => '1h', column => 'backlog' );
        1;
    };
    ok( $scoped, 'and it refuses a column, rather than accepting one it will not read' );

    my $entered = !eval {
        $tira->policy_add( project => $root, rule => 'upgrade-unreviewed',
            action => 'bridge-reminder', age => '1h', enter => 'backlog' );
        1;
    };
    ok( $entered, 'and refuses an entry column for the same reason' );
}

# --- a gate card nobody has touched is reported ----------------------------
#
# The whole card. It rests in backlog, where nothing else looks.

{
    my ( $tira, $root, $store, $clock ) = board();
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Tira upgraded 5.77 -> 5.84 - review what changed and what to declare',
        labels => ['upgrade-gate'], priority => 5 );
    $tira->checklist_add( project => $root, ref => $card->{ref}, author => 'tira',
        item => 'Read the new commands (d2 tira.usage)', status => 'pending' );

    ${$clock} = '2026-09-06T11:00:00Z';
    my $hits = found( $tira, $root, $store );

    is( scalar @{$hits}, 1,
        'an upgrade-gate card nobody has acted on IS reported, even resting in backlog where '
          . 'card-duration, checklist-idle and card-still all decline to look' );
    like( $hits->[0]{ref} // '', qr/\Q$card->{ref}\E/,
        'and the finding names the card, so it can be acted on without hunting for it' );
}

# --- a card somebody has started is not reported ---------------------------
#
# The rule asks whether the upgrade was reviewed, not whether it was finished.
# One ticked item is somebody having read it, which is all this was ever for.

{
    my ( $tira, $root, $store, $clock ) = board();
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Tira upgraded 5.77 -> 5.84 - review what changed and what to declare',
        labels => ['upgrade-gate'], priority => 5 );
    $tira->checklist_add( project => $root, ref => $card->{ref}, author => 'tira',
        item => 'Read the new commands (d2 tira.usage)', status => 'pending' );
    $tira->checklist_update( project => $root, ref => $card->{ref}, author => 'claude',
        id => 'CHK-001', status => 'done',
        command => ['d2 tira.usage'], proof => ['read the command reference'] );

    ${$clock} = '2026-09-06T11:00:00Z';
    is( scalar @{ found( $tira, $root, $store ) }, 0,
        'a gate card whose checklist has been started is left alone - the rule asks whether '
          . 'anybody reviewed the upgrade, not whether they finished' );
}

# --- an ordinary backlog card is never reported ----------------------------
#
# The direction that would make this rule worthless. Backlog holds over a
# hundred cards on the real board; a rule that spoke about them would be
# scrolled past, and then it protects nothing.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->create_record( project => $root, type => 'ticket',
        title => 'an ordinary card waiting its turn' );

    ${$clock} = '2026-09-06T11:00:00Z';
    is( scalar @{ found( $tira, $root, $store ) }, 0,
        'a card without the gate label is not reported, however long it rests - backlog is '
          . 'for waiting and this rule must not turn that into noise' );
}

# --- and not before its age ------------------------------------------------
#
# The gate raises the card the moment an upgrade lands. Reporting it in the
# same breath would be the board nagging about something it just did.

{
    my ( $tira, $root, $store, $clock ) = board();
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Tira upgraded 5.77 -> 5.84 - review what changed and what to declare',
        labels => ['upgrade-gate'], priority => 5 );
    $tira->checklist_add( project => $root, ref => $card->{ref}, author => 'tira',
        item => 'Read the new commands (d2 tira.usage)', status => 'pending' );

    ${$clock} = '2026-09-06T09:30:00Z';
    is( scalar @{ found( $tira, $root, $store ) }, 0,
        'and nothing is said within the declared age, so the board does not nag about an '
          . 'upgrade it has only just finished' );
}

# --- the gate marks the card it raises -------------------------------------
#
# Without this the rule has nothing durable to match on. A title string would
# couple the rule to wording somebody will reasonably reword.

{
    my $engine = Suite::engine_source();
    # non-empty is the whole claim: the checks below would pass on an
    # unreadable file's emptiness alone otherwise.
    like( $engine, qr/\S/, 'the engine source is there to be read' );

    my ($gate) = $engine =~ /(sub \s+ _raise_upgrade_gate \b .*?\n\})/xs;
    ok( defined $gate, 'the upgrade gate was found, to read what it marks its card with' );
    like( $gate // '', qr/upgrade-gate/,
        'the gate labels the card it raises, so a rule can find it without matching a title '
          . 'somebody will reword' );
}

done_testing();

__END__

=head1 NAME

575-an-upgrade-nobody-reviewed.t - a gate-raised upgrade card is chased wherever it rests

=head1 DESCRIPTION

TKT-957. The upgrade gate lands its card in C<backlog>, and nothing looks
there: no column-scoped policy names that column, and C<card-still> skips it
because C<_resting_columns> excludes protected columns. Backlog resting is
correct - a card waiting in a queue is not a stalled card - so the rule watches
the card rather than the column.

C<upgrade-unreviewed> reports a gate-raised card whose checklist nobody has
started, after its declared age. A card somebody has begun is left alone, and a
card without the gate's label is never reported, because backlog is for waiting
and a rule that spoke about all of it would be scrolled past.

=cut
