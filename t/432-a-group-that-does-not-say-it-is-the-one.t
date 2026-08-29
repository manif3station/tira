#!/usr/bin/env perl
# The card dialog groups required actions by column and never says which column
# the card is in.
#
# It renders one card-required__group per column, and on a card with a dozen
# columns of history that is a dozen headings of which exactly one is the work
# in front of you. Nothing marks it. The section's own count is card-wide -
# "Required actions (18/75)" - so it answers how much of the card's whole life
# is finished rather than what is owed HERE.
#
# TKT-598 already solved this for the CLI: tira.required-action.list --blocking
# answers "what is in the way now" without attempting a move. The browser has
# the same problem and did not get the same answer, which is why this is drift
# rather than a missing feature.
#
# THE SELECTION MUST BE _unmet_in_column's, NOT A SECOND ONE. That sub already
# decides it for the CLI - this column, minus exemptions, minus anything already
# done - and the card's third acceptance criterion is that the dialog's number
# matches --blocking. Two implementations cannot be held to that; one selection
# served two ways can. So this file asserts the provider exists and agrees with
# _unmet_in_column, rather than asserting some number appears somewhere.
#
# The rendering half is a Playwright case (t/playwright/), because what a group
# LOOKS like is interpreted by a person and does not belong in a .t file. What
# belongs here is the contract underneath it: a provider, and its agreement with
# the selection the CLI already uses.

use strict;
use warnings;

use File::Find ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
require Tira::CLI::Browser;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $now = '2026-08-29T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
$tira->project_new(
    name => 'Grouped', dir => $root, members => ['claude'],
    columns => ['backlog, tests-red, implement, done'],
    sow_prefix => 'GS', epic_prefix => 'GE', ticket_prefix => 'GT',
);

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'a card with a history',
    author => 'claude' );
my $ref = $card->{ref};
ok( $ref, "a card to group actions on - $ref" );

# --- the provider the dialog needs ------------------------------------------
#
# Asked of browser_providers rather than of the rendered page, because the
# page's appearance is the Playwright case's business and this is the contract
# the page will be built on. A provider that does not exist cannot be rendered
# wrongly.

my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
ok( exists $providers{unmet_in_column},
    'browser_providers exposes what is unmet in the card\'s current column, '
      . 'so the dialog can mark that group without deciding for itself which '
      . 'items count' );

# --- and it must agree with the CLI, not merely exist ------------------------
#
# The point of the card. _unmet_in_column is the selection tira.required-action
# .list --blocking already uses; if the provider answers differently then the
# dialog and the CLI disagree about what is in the way, which is worse than the
# dialog saying nothing at all.

SKIP: {
    skip 'no provider to compare against', 2 if !$providers{unmet_in_column};

    my $record = $tira->record_show( project => $root, ref => $ref );
    my $expected = Tira::CLI::_unmet_in_column( $record, $record->{column} );

    my $answered = eval { $providers{unmet_in_column}->( { ref => $ref } ) };
    ok( defined $answered, 'the provider answers for a card' );

    my $seen = eval { Cpanel::JSON::XS::decode_json($answered) };
    is_deeply(
        [ sort map { $_->{item} // '' } @{ $seen->{items} // [] } ],
        [ sort map { $_->{item} // '' } @{$expected} ],
        'and answers with exactly what _unmet_in_column selects - the same '
          . 'items tira.required-action.list --blocking reports, so the dialog '
          . 'and the CLI cannot disagree about what is in the way'
    );
}

# --- and it refuses a call that names no card --------------------------------
#
# The guard was written and never exercised, which the coverage gate caught:
# Browser.pm measured 99.7% statement against 100.0% subroutine - both provider
# subs called, one statement inside one of them never reached. That statement is
# this die, and a guard nobody has run is a guess about what happens.
#
# It matters beyond the percentage. Without it the provider would call
# record_show with an undefined ref, and what that does is a question nobody has
# answered; with it, the caller is told what it failed to supply. The other
# per-card providers refuse the same way - police_log's "A card reference is
# required" is the line this one was modelled on.

my $refused = !eval { $providers{unmet_in_column}->( {} ); 1 };
ok( $refused, 'the provider refuses a call that names no card, rather than '
      . 'asking the engine for a record with no reference' );
like( $@, qr/card reference/i,
    'and says what was missing - ' . ( $@ =~ s/\s+\z//r || '(nothing)' ) );

# --- and the detail provider builds the list the dialog renders ---------------
#
# THE CASE THE FEATURE EXISTS FOR, AND UNTIL NOW NOTHING REACHED IT. The
# assertions above ask the standalone provider; the browser case uses a fixture
# with unmet_in_column pre-baked. Neither exercises the detail provider building
# a NON-EMPTY list, so on every card the tests used, the current column had no
# unmet items, @{$unmet} was empty, and the map inside
#
#     items => [ map { $_->{id} } @{$unmet} ],
#
# never ran its body once. The coverage gate refused this card twice for that
# line while the suite stayed green at 8,797 tests, which is exactly the hole a
# green suite cannot report.
#
# It is worth covering for its own sake rather than for the percentage: this is
# the payload the dialog reads, and until now nothing proved it carries the
# right ids when there is anything to carry.

my $owed = $tira->required_item_add(
    project => $root, ref => $ref, author => 'claude',
    column => 'backlog', item => 'something owed in this column', status => 'pending' );
ok( $owed, 'a required action added in the column the card is sitting in' );

my $detail = eval { $providers{detail}->( { ref => $ref } ) };
my $payload = eval { Cpanel::JSON::XS::decode_json($detail) };
is( $payload->{unmet_in_column}{column}, $payload->{column},
    'the record the dialog reads carries the unmet count for its OWN column' );
cmp_ok( $payload->{unmet_in_column}{count}, '>', 0,
    'and the count is what is actually owed there - '
      . ( $payload->{unmet_in_column}{count} // 'undef' ) );
is_deeply(
    $payload->{unmet_in_column}{items},
    [ map { $_->{id} } @{ Tira::CLI::_unmet_in_column( $payload, $payload->{column} ) } ],
    'and the ids are exactly the ones _unmet_in_column selects, built by the '
      . 'provider rather than pre-baked by a fixture'
);

# --- what this must not cost -------------------------------------------------
#
# Green now and green after. The dialog already groups by column; this card adds
# a marker to one group, and losing the grouping while adding the marker would
# be a poor trade.

my $helpers = '';
File::Find::find(
    {   no_chdir => 1,
        wanted   => sub {
            return if !/live-helpers\.js\z/;
            open my $handle, '<', $File::Find::name or die "$File::Find::name: $!";
            $helpers = do { local $/; <$handle> };
            close $handle;
        },
    },
    'lib'
);
ok( $helpers, 'the dialog\'s helpers were read - ' . length($helpers) . ' bytes' );
like( $helpers, qr/byColumn/,
    'the dialog still groups required actions by column, which this card marks '
      . 'rather than replaces' );

done_testing();

__END__

=head1 NAME

t/432-a-group-that-does-not-say-it-is-the-one.t - the card dialog must mark the
required-action group for the column the card is actually in

=head1 DESCRIPTION

The dialog renders one group per column. On a card with a dozen columns of
history that is a dozen headings, exactly one of which is the work in front of
you, and nothing says which. The section's count is card-wide - C<Required
actions (18/75)> - so it reports how much of the card's whole life is finished
rather than what is owed in this column.

C<tira.required-action.list --blocking> answered this for the CLI in TKT-598.
The browser has the same problem and did not get the same answer.

=head2 Why this asserts a provider rather than a number on the page

The card's third acceptance criterion is that the dialog's count matches
C<--blocking>. That can only hold if both come from one selection, and
C<Tira::CLI::_unmet_in_column> is already that selection for the CLI - this
column, minus exemptions, minus anything already done. So this file asks whether
a provider exists and whether it agrees with C<_unmet_in_column>, which is the
contract; what the marked group looks like is a Playwright case, because
appearance is interpreted by a person and does not belong in a C<.t> file.

The last two assertions are green before this card and must stay green: the
dialog already groups by column, and this work marks one group rather than
replacing the grouping.

=cut
