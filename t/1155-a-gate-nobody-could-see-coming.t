#!/usr/bin/env perl
# TKT-647. -o human rendered '## Checklist' - which never gates a move out of
# a column - but omitted the required-actions section entirely, even when the
# card carried pending required_items that DO gate every move. Measured live
# on TKT-649 (2026-09-22): 2 genuinely pending required actions, and
# `d2 tira.ticket.show --ref TKT-649 -o human` named neither. An agent reading
# a card the documented way ("-o human, add -o json to parse") saw a checklist
# and no sign anything was blocking its move - the first place it learned the
# requirement text was the refusal when it tried to move.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Tira;

my $tira = Tira->new;

# --- a card with pending required_items names them in -o human --------------

{
    my $data = {
        ref              => 'R-1',
        title            => 'A card with real work outstanding',
        required_items   => [
            { id => 'REQ-001', column => 'tests-red', status => 'pending', item => 'Write a red test' },
            { id => 'REQ-002', column => 'tests-red', status => 'done',    item => 'Already satisfied' },
        ],
    };
    my $human = $tira->format_output( $data, output => 'human' );

    like( $human, qr/^## Required Actions/m, 'a Required Actions heading exists, distinct from Checklist' );
    like( $human, qr/REQ-001/, 'the pending item is named' );
    like( $human, qr/Write a red test/, 'and its text is shown' );
    like( $human, qr/REQ-002/, 'the done item is named too' );

    # The whole reason this card was filed: pending must not read the same as
    # done, or the section is decoration rather than the answer to "what is
    # blocking this card". Codex review: the earlier form of this assertion
    # (comparing whole lines that already differ by id/text) would still pass
    # with the status token removed entirely - assert the literal token instead.
    like( $human, qr/\[pending\] REQ-001/, 'the pending item literally carries the pending token' );
    like( $human, qr/\[done\] REQ-002/,    'and the done item literally carries the done token' );

    # And Required Actions sits after Checklist, not before it or interleaved.
    my $checklist_at = index( $human, '## Checklist' );
    my $required_at  = index( $human, '## Required Actions' );
    ok( $checklist_at >= 0 && $required_at > $checklist_at,
        'Required Actions is placed after Checklist' );
}

# --- a card with none says so, matching the empty-Checklist convention ------

{
    my $data = { ref => 'R-2', title => 'Nothing outstanding', required_items => [] };
    my $human = $tira->format_output( $data, output => 'human' );
    like( $human, qr/^## Required Actions/m, 'the heading still appears with zero items' );
    like( $human, qr/_Empty\._/, 'and says so the same way an empty Checklist does' );
}

# --- and -o json/-o toon are unaffected --------------------------------------

{
    my $data = {
        ref            => 'R-3',
        title          => 'x',
        required_items => [ { id => 'REQ-009', column => 'verify', status => 'pending', item => 'x' } ],
    };
    my $json = $tira->format_output( $data, output => 'json' );
    unlike( $json, qr/## Required Actions/, 'json output carries no human heading' );
    like( $json, qr/REQ-009/, 'json output still carries the raw data' );
}

done_testing;

__END__

=head1 NAME

1155-a-gate-nobody-could-see-coming.t - -o human names required_items, the
thing that actually gates a move

=head1 DESCRIPTION

TKT-647. C<-o human> rendered a Checklist section (which never gates
anything) and omitted required_items entirely (which gates every move out of
a column). Measured live on TKT-649: 2 pending required actions, invisible to
C<-o human>. Now a C<## Required Actions> section lists each item's id,
status and text, the same convention the Checklist section already uses for
"empty means say so".

=cut
