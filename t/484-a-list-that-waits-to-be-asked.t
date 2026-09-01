#!/usr/bin/env perl
# TKT-746's second lift: the tasklist_* / _tasklist_* subs (lib/Tira.pm's
# shared to-do queue - tasklist_add, tasklist_list, tasklist_next, and the
# rest) move out of the engine into lib/Tira/Tasklist.pm, required lazily at
# the call site the same way TKT-830 moved the TOON overrides into
# lib/Tira/Toon.pm. This file is written RED, before the lift: it names what
# the lift has to prove, and fails against the pre-lift code because
# lib/Tira/Tasklist.pm does not exist yet.
#
#   1. The module stands on its own - compiles and is usable without
#      Tira.pm having been loaded first (t/431's precedent for the CLI
#      submodules, and t/483's precedent for Tira::Toon).
#   2. The laziness is real - a command that never touches the tasklist
#      never pulls Tira::Tasklist into %INC.
#   3. Entry points keep their old names - Tira->new->tasklist_add(...)
#      still works exactly as it does today, per the Tira::CLI::Browser
#      precedent ("the entry point keeps its old name").

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';

{
    my $out = qx{$^X -Ilib -e 'require Tira::Tasklist; print "loaded\\n"' 2>&1};
    is( $?, 0, 'Tira::Tasklist exits clean when required on its own' );
    like( $out, qr/loaded/, 'and it ran, without Tira.pm ever being loaded' );
}

require Tira;

{
    my $tira = Tira->new;
    $tira->format_output( { a => 1 }, output => 'json' );
    ok( !exists $INC{'Tira/Tasklist.pm'},
        'a command that never touches the tasklist leaves Tira::Tasklist out of %INC' );
}

{
    my $tira = Tira->new;
    eval { $tira->tasklist_add( text => 'placeholder', session => 'x' ) };
    ok( exists $INC{'Tira/Tasklist.pm'},
        'tasklist_add loads Tira::Tasklist at the call site' );
}

# --- a second attachment through the content path ---------------------------
#
# tasklist_task_attach_add_content dedupes by (sha, extension) against what the
# item already carries, and that grep body only runs when there IS something to
# compare against - which no test reached, because every existing caller adds
# exactly one attachment to a fresh item. It read as covered while the sub
# lived in lib/Tira.pm: one uncovered statement in ~14,400 lines rounds to
# 100.0%. Lifting the concern into a 692-line file shrank the denominator and
# the hole became visible - the same way TKT-830's lift surfaced four untested
# branches in the TOON overrides. Both directions are asserted, because a
# dedup that never matches and a dedup that always matches are both wrong and
# only one of them is caught by adding the same file twice.

{
    my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
    my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, 'board' );
    $tira->project_new(
        name => 'Attached', dir => $root, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'ATS', epic_prefix => 'ATE', ticket_prefix => 'ATT',
    );

    my $item = $tira->tasklist_add( project => $root, text => 'carries files' );

    $tira->tasklist_task_attach_add_content( project => $root, id => $item->{id},
        filename => 'first.txt', content => 'one' );

    # Different bytes: the grep runs, finds no match, and the second reference
    # is added beside the first.
    my $two = $tira->tasklist_task_attach_add_content( project => $root, id => $item->{id},
        filename => 'second.txt', content => 'two' );
    is( scalar @{ $two->{attachments} }, 2,
        'a second, different attachment is added beside the first' );

    # Same bytes and same extension: the grep runs and finds the existing one,
    # so nothing is pushed and the count holds.
    my $again = $tira->tasklist_task_attach_add_content( project => $root, id => $item->{id},
        filename => 'second.txt', content => 'two' );
    is( scalar @{ $again->{attachments} }, 2,
        're-adding identical bytes under the same name does not duplicate the reference' );

    # Same bytes under a different extension is a different reference, which is
    # what makes the predicate a pair rather than a sha alone.
    my $other_ext = $tira->tasklist_task_attach_add_content( project => $root, id => $item->{id},
        filename => 'second.md', content => 'two' );
    is( scalar @{ $other_ext->{attachments} }, 3,
        'the same bytes under a different extension is a separate reference' );
}

done_testing();

__END__

=head1 NAME

t/484-a-list-that-waits-to-be-asked.t - Tira::Tasklist loads standalone, and only on request

=head1 DESCRIPTION

Written red, ahead of TKT-746's second lift (TKT-832): proves the two
properties any lifted engine module has to have (standalone load, lazy
%INC) for the tasklist concern, the way t/483 already proved them for the
TOON overrides.

=cut
