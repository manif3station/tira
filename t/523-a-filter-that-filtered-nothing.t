#!/usr/bin/env perl
# --status, offered by every command and read by nine of them.
#
# TKT-748, EPC-007. His answer to Q-113, 2026-09-03: "if --status goes with
# *.list like this. We should should only those ones with the wanted status. It
# is very straightforward to me. No?"
#
# --status is parsed in the GLOBAL option table at lib/Tira/CLI.pm:165, so every
# command in the tool accepts it. Only the commands that read it honour it, and
# nothing tells the caller which is which.
#
# THE SWEEP THAT SCOPED THIS, run in a container over all twenty *.list
# entrypoints against a board carrying two items of differing status in every
# list that has one (KD11 on the card holds the whole table):
#
#   checklist.list           done/pending   2 / 2   *** IGNORED ***
#   question.list            answered/new   2 / 1   filters
#   required-action.list     done/pending   2 / 1   filters
#   tasklist.list            0/2            2 / 1   filters
#   ...and fifteen more that accept --status with no status field to act on
#
# So there are two faults with one cause, and this file asserts both:
#
#   ONE LIST IGNORES IT. checklist.list has a status field, is offered the
#   option, and returns everything.
#
#   FIFTEEN ACCEPT IT WITH NOTHING TO FILTER ON. comment.list, column.list,
#   history.list, job.list, record.list and the rest take --status and exit 0.
#
# WHY THE SECOND HALF IS A REFUSAL AND THE FIRST IS NOT. His answer settles it:
# --status on a list that HAS a status is an option the command should honour.
# A list with no status field cannot honour it at any price, and this codebase
# already has the mechanism for that case - %OPTION_READ_BY, whose entries the
# --dry-run refusal on this very card came from.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';

# ABSOLUTE, and this is not decoration. This file chdir's into the board it
# builds, because the CLI finds its project from the working directory and has
# no --project option to be told instead. Tira::CLI loads its sub-modules
# lazily, so a relative lib/ in @INC stops resolving the moment the chdir
# happens - and the die is caught by the runner below, which reports it as a
# command that returned no items rather than as a module that could not be
# found. It cost three green controls that looked like a broken fixture: prove
# happens to export an absolute PERL5LIB and hid it, and bare perl did not.
BEGIN {
    require File::Spec;
    unshift @INC, map { File::Spec->rel2abs($_) } qw(lib t/lib);
}

use Tira;
use Tira::CLI;

# Running a command the way a caller does - through the shared option parser,
# which is the layer that accepts --status for everybody. Calling the engine
# directly would skip the half of this card that is about the parser.
sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    my $ok = eval {
        local *STDOUT;
        local *STDERR;
        open STDOUT, '>', \$out or die "stdout: $!";
        open STDERR, '>', \$err or die "stderr: $!";
        Tira::CLI->run(
            command => $command,
            argv    => [@argv],
            ( $command =~ /\Arecord\./ ? ( type => 'ticket' ) : () ),
        );
        1;
    };
    my $why = $@ // '';

    # The CLI reports some failures by dying and some by printing an error and
    # exiting non-zero, and it does not always put that error on the same
    # stream. A first version read STDOUT alone and called eleven working
    # refusals acceptances, which is the same mistake as grepping output for
    # the success line: what is not looked at reads as nothing happening.
    if ( !length $why ) {
        for my $stream ( $out, $err ) {
            next if $stream !~ /"error"\s*:\s*"((?:[^"\\]|\\.)*)"|^error:\s*"?(.+)/m;
            ( $why, $ok ) = ( ( $1 // $2 ), 0 );
            last;
        }
    }
    return { out => $out, err => $err, ok => $ok, why => $why };
}

sub items {
    my ($result) = @_;
    my @found = $result->{out} =~ /"id"\s*:/g;
    return scalar @found;
}

my $HOME = File::Spec->rel2abs('.');

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        project => $root,
        name    => 'Status', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'STS', epic_prefix => 'STE', ticket_prefix => 'STT',
    );
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Filter fixture', description => 'x', author => 'claude' )->{ref};

    # Two of each, one marked, so a filter has something to tell apart. A
    # fixture where every item shared a status would pass an ignored filter and
    # a working one alike.
    my @pair = ( command => ['ran it'], proof => ['it worked'] );
    $tira->checklist_add( project => $root, ref => $card,
        item => 'chk one', status => 'pending', author => 'claude' );
    $tira->checklist_add( project => $root, ref => $card,
        item => 'chk two', status => 'pending', author => 'claude' );
    my $chk = $tira->checklist_list( project => $root, ref => $card );
    $tira->checklist_update( project => $root, ref => $card,
        id => $chk->[0]{id}, status => 'done', @pair, author => 'claude' );

    $tira->required_item_add( project => $root, ref => $card,
        item => 'ra one', status => 'pending', author => 'claude' );
    $tira->required_item_add( project => $root, ref => $card,
        item => 'ra two', status => 'pending', author => 'claude' );
    my $ras = $tira->required_item_list( project => $root, ref => $card );
    $tira->required_item_update( project => $root, ref => $card,
        id => $ras->[0]{id}, status => 'done', @pair, author => 'claude' );

    my $task = $tira->tasklist_add( project => $root, text => 'task one' );
    $tira->tasklist_add( project => $root, text => 'task two' );
    $tira->tasklist_update( project => $root, id => $task->{id}, status => 'done' );

    $tira->comment_add( project => $root, ref => $card, text => 'c one', author => 'claude' );
    $tira->comment_add( project => $root, ref => $card, text => 'c two', author => 'claude' );

    chdir $root or die "chdir $root: $!";
    return ( $tira, $root, $card );
}

# --- the three that filter today, and must go on filtering -------------------
#
# The controls, and they are load-bearing twice over: they prove the harness can
# tell a filtered answer from an unfiltered one, and they are the fifth
# acceptance criterion - a refusal written carelessly would break them.

{
    my ( $tira, $root, $card ) = board();

    is( items( cli( 'required-action.list', '--ref', $card, '--status', 'done', '-o', 'json' ) ),
        1, 'required-action.list --status done returns the one done item - it '
          . 'filters today and must keep filtering' );

    is( items( cli( 'required-action.list', '--ref', $card, '-o', 'json' ) ),
        2, 'and the unfiltered call returns both, which is what makes the line '
          . 'above a measurement rather than a card that happened to hold one' );

    is( items( cli( 'tasklist.list', '--status', 'done', '-o', 'json' ) ),
        1, 'tasklist.list --status done filters, as it does today' );

    # The third filtering reader, given something to filter. The first version
    # of this asserted a count of 0 on a card with no questions, which passes
    # whether question.list filters or ignores the option - an assertion that
    # cannot fail honestly is worth less than none.
    $tira->question_add( project => $root, ref => $card, text => 'q one?',
        reason => 'r', options => [ 'a', 'b' ], author => 'claude' );
    $tira->question_add( project => $root, ref => $card, text => 'q two?',
        reason => 'r', options => [ 'a', 'b' ], author => 'claude' );
    # question_list answers a hash - ref, title, the questions and the
    # instruction the agent is meant to act on - not a bare list.
    my $asked = $tira->question_list( project => $root, ref => $card )->{questions};
    $tira->question_answer( project => $root, ref => $card,
        id => $asked->[0]{id}, text => 'a', author => 'claude' );

    is( scalar @{ $tira->question_list( project => $root, ref => $card,
            status => 'answered' )->{questions} },
        1, 'question.list --status answered returns the one that was answered - '
          . 'the third filtering command, and it filters today' );

    is( scalar @{ $tira->question_list( project => $root, ref => $card )->{questions} },
        2, 'while an unfiltered read returns both, which is what makes the line '
          . 'above a measurement' );

    chdir $HOME;
}

# --- the list that IGNORES it ------------------------------------------------

{
    my ( $tira, $root, $card ) = board();

    is( items( cli( 'checklist.list', '--ref', $card, '-o', 'json' ) ),
        2, 'the card carries two checklist items - the control for everything '
          . 'below, and an unfiltered read must stay unfiltered' );

    is( items( cli( 'checklist.list', '--ref', $card, '--status', 'done', '-o', 'json' ) ),
        1, 'CHECKLIST.LIST --STATUS DONE RETURNS ONLY THE DONE ITEM. Today it '
          . 'returns BOTH: the option is parsed, checklist_list never reads it, '
          . 'and the caller gets every item back dressed as a filtered answer' );

    is( items( cli( 'checklist.list', '--ref', $card, '--status', 'pending', '-o', 'json' ) ),
        1, 'and --status pending returns only the pending one - the other '
          . 'direction, so a filter that returned a fixed half would fail here' );

    chdir $HOME;
}

# 'To Do' is the third value, and it is the one a careless filter loses.
# checklist_add's own vocabulary is pending, done and 'To Do', and 'To Do' is
# what this board itself writes on move-in - so a filter that only understood
# two of the three would silently drop real items, which is the same fault
# wearing different clothes.

{
    my ( $tira, $root, $card ) = board();

    $tira->checklist_add( project => $root, ref => $card,
        item => 'chk three', status => 'To Do', author => 'claude' );

    is( items( cli( 'checklist.list', '--ref', $card, '--status', 'To Do', '-o', 'json' ) ),
        1, "'To Do' is a status this filter understands - it is the spelling the "
          . 'board writes on move-in, and a filter that knew only pending and '
          . 'done would make every unmarked item unfindable' );

    is( items( cli( 'checklist.list', '--ref', $card, '-o', 'json' ) ),
        3, 'and the unfiltered read still returns all three' );

    my $bad = cli( 'checklist.list', '--ref', $card, '--status', 'Donee', '-o', 'json' );
    ok( !$bad->{ok},
        'a status the vocabulary does not contain is REFUSED rather than '
          . 'matching nothing - required_item_list already refuses on exactly '
          . 'this reasoning, and an empty list would read as "no items are done"' );
    like( $bad->{why}, qr/Donee/,
        'and the refusal quotes what was given, so a misspelling is visible' );

    chdir $HOME;
}

# --- and the lists with no status field REFUSE it ----------------------------
#
# Fifteen commands in the sweep took --status with nothing to act on. These are
# a sample across the shapes: a card-scoped list, a board-scoped list, a
# project-scoped one, and record.list - which is what ticket.list, epic.list and
# sow.list all reach, and is the one a CLI-only reading would have missed.

{
    my ( $tira, $root, $card ) = board();

    my %scoped = (
        'comment.list' => [ '--ref', $card ],
        'column.list'  => [],
        'job.list'     => [],
        'record.list'  => [],
    );

    for my $command ( sort keys %scoped ) {
        my $result = cli( $command, @{ $scoped{$command} }, '--status', 'done', '-o', 'json' );

        ok( !$result->{ok},
            "$command REFUSES --status. It has no status field to filter on, so "
              . 'accepting the option means answering a question nobody asked '
              . 'and not saying so' );

        like( $result->{why}, qr/--status/,
            'and the refusal names the option, which is what makes it '
              . 'actionable rather than a generic error' );
    }

    chdir $HOME;
}

# The two instances the card never named, found by walking the readers rather
# than by being bitten. Tira::CLI::Records passes --status into every question
# action; question_add and question_update do not read it, so both accept it and
# drop it. Neither is a list, so the refusal is the whole of their fix.

{
    my ( $tira, $root, $card ) = board();

    my $ask = cli( 'question.ask', '--ref', $card, '--text', 'why?',
        '--reason', 'because', '--option', 'a', '--option', 'b',
        '--status', 'new', '-o', 'json' );

    ok( !$ask->{ok},
        'question.ask refuses --status - question_add never reads it, so today '
          . 'the option is accepted, dropped, and the new question printed back, '
          . 'which reads as confirmation' );

    chdir $HOME;
}

# --- the nine readers, named -------------------------------------------------
#
# The refusal is driven by a declared list, and a list that is too narrow breaks
# a working command. %OPTION_READ_BY's own text records two near-misses of
# exactly that kind: --field counted one reader from the CLI and would have
# broken search and replace; --text counted eleven from the engine and would
# have broken dev.found.bug_or_improvement.
#
# So the entry is asserted by name here as well as by behaviour above. Behaviour
# alone would need a fixture for every one of the twenty-plus commands.

{
    require Tira::CLI::Options;

    # ASKED OF THE GUARD ITSELF, not of the file it is written in. The first
    # version grepped Options.pm for each command name and five of the nine
    # passed against unfixed code - because the entry's prose names four lists
    # in its own "use this instead" sentence. An assertion that a word appears
    # somewhere in a file cannot tell a rule from a comment about a rule.
    my $refuses = sub {
        my ($command) = @_;
        my $ok = eval {
            Tira::CLI::Options::_refuse_unread_options( $command, { status => 'done' } );
            1;
        };
        return $ok ? 0 : 1;
    };

    for my $reader (
        qw(checklist.add checklist.list checklist.update question.list),
        qw(required-action.add required-action.list required-action.update),
        qw(tasklist.list tasklist.update) )
    {
        ok( !$refuses->($reader),
            "$reader is a reader and is NOT refused - it genuinely reads "
              . '--status, and a reader list too narrow by one name breaks a '
              . 'command that works today. The table has two of those in its own '
              . 'history: --field counted one reader from the CLI and would have '
              . 'broken search and replace' );
    }

    # And the other side of the same rule, so the loop above cannot be satisfied
    # by a guard that refuses nothing at all.
    for my $stranger (qw(column.list comment.list job.list record.list question.ask)) {
        ok( $refuses->($stranger),
            "$stranger IS refused - it has nothing to act on, and the loop above "
              . 'would pass against a table with no status entry in it if this '
              . 'were not asserted beside it' );
    }
}

done_testing();

__END__

=head1 NAME

523-a-filter-that-filtered-nothing.t - C<--status> on the commands that read it

=head1 WHY

TKT-748, and his answer to Q-113: C<--status> on a C<*.list> should return only
the items with that status. C<--status> is parsed globally, so every command
accepts it; a sweep of all twenty C<*.list> entrypoints found one list that has
a status field and ignores the option (C<checklist.list>) and fifteen that
accept it with no status field to act on.

=head1 WHAT IS ASSERTED

That the three lists which filter today go on filtering, which is both the
control and the fifth acceptance criterion; that C<checklist.list> filters in
both directions and understands all three of its statuses including C<To Do>,
refusing a value outside that vocabulary; that a list with no status field
refuses C<--status> by name; that C<question.ask> - an instance the card never
named, found by walking the readers - refuses it too; and that the declared
reader list names all nine commands that genuinely read it.

=head1 WHAT IS NOT ASSERTED

The class fix: deriving the reader list rather than declaring it. KD3 raises it
and KD8 settles that it is a separate card - his answer establishes that
C<--status> on a list is an option a command should B<honour>, so it was never
an instance of "options a command cannot act on".

=cut
