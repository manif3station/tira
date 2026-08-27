#!/usr/bin/env perl

# A card goes back to the queue and its tasks still say somebody is on them.
#
# The board already understands that retreating undoes claims of progress: a
# backward move resets every required item tagged with a column between the
# destination and the origin, keeping its proof (TKT-455). Tasks were never
# part of that. So a card returns to backlog, nobody is working it, and its
# tasklist items go on reading "working" until an agent remembers to say
# otherwise - which is a second command nobody is prompted to run.
#
# The owner asked for it to happen on the move: "If a ticket or epic or sow
# linked to any tasks. Once moved back to backlog. Those tasks status will be
# automatically reset to pending without the agent run second command or a
# setup any new required action item on the column."
#
# Backlog is the anchor because it is the default builtin column - a fix point
# every board has, needing no per-board configuration.
#
# Three things are decided rather than implied, and each has its own assertion:
#
#   A DONE task is left alone. It records work that actually happened, and a
#   card retreating does not unmake it.
#
#   The reset CROSSES THE SESSION BOUNDARY. Tasklist items are session-scoped
#   (TKT-537's privacy boundary, with --all-sessions as the opt-in), and the
#   tasks that most need resetting on a multi-agent board belong to somebody
#   else's session. A reset that respected the boundary would silently do
#   nothing in exactly the case it exists for.
#
#   A task linked to MORE THAN ONE card is not reset, and the move SAYS SO.
#   Q-088, answered by the owner: "Never reset a task with more than one linked
#   card, and say so in the output so it is visible rather than silent." There
#   is no answer true about both cards at once, so the skip is a choice - and a
#   silent skip is indistinguishable from the feature being broken, while the
#   person moving the card is the only one positioned to judge whether that
#   task should have been reset by hand.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-27T09:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name          => 'Retreating', dir         => $root,
    members       => ['ada'],      columns     => ['backlog, implement, done'],
    sow_prefix    => 'RTS',        epic_prefix => 'RTE',
    ticket_prefix => 'RTT',        author      => 'ada',
);

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card with tasks under it', author => 'ada',
);
$tira->record_move(
    project => $root, type => 'ticket', ref => $card->{ref}, column => 'implement', author => 'ada',
);

sub add_task {
    my ( $text, $status, %opt ) = @_;
    my $task = $tira->tasklist_add(
        project => $root, text => $text, author => 'ada',
        ( $opt{session} ? ( session => $opt{session} ) : () ),
    );
    $tira->tasklist_task_ref_link(
        project => $root, id => $task->{id}, refs => $opt{refs} // [ $card->{ref} ],
        ( $opt{session} ? ( session => $opt{session} ) : () ),
    );
    $tira->tasklist_update(
        project => $root, id => $task->{id}, status => $status,
        ( $opt{session} ? ( session => $opt{session} ) : () ),
    ) if defined $status;
    return $task->{id};
}

sub status_of {
    my ($id) = @_;
    for my $item ( @{ $tira->tasklist_list( project => $root, all_sessions => 1 ) } ) {
        return $item->{status} if $item->{id} eq $id;
    }
    return undef;
}

my $working = add_task( 'Working on the card that is about to retreat', 'working' );
my $finished = add_task( 'Something that actually got done', 'done' );
my $elsewhere = add_task( 'Another agent\'s task on the same card', 'working', session => 'other-agent' );

my $second_card = $tira->create_record(
    project => $root, type => 'ticket', title => 'A second card sharing a task', author => 'ada',
);
my $shared = add_task(
    'A task belonging to two cards at once', 'working',
    refs => [ $card->{ref}, $second_card->{ref} ],
);

# --- moving back to backlog ---------------------------------------------------

my $said = '';
{
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \$said      or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    eval {
        Tira::CLI->run(
            command => 'record.move', tira => $tira,
            argv    => [ '--type', 'ticket', '--ref', $card->{ref},
                         '--column', 'backlog', '--author', 'ada', '-o', 'toon' ],
        );
    };
    select $old;
}

is( $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} )->{column},
    'backlog', 'the card is back in backlog' );

is( status_of($working), 0,
    'a task that was working on the retreating card is reset to pending, with no second command' );

is( status_of($finished), 2,
    'a task already done stays done - it records work that happened, and a card retreating does not unmake it' );

is( status_of($elsewhere), 0,
    'a task owned by another session is reset too - those are the ones a multi-agent board most needs reset' );

is( status_of($shared), 1,
    'a task linked to more than one card is NOT reset - there is no answer true about both cards at once' );

like( $said, qr/\Q$shared\E/,
    'and the move says which task it skipped, because a silent skip looks exactly like the feature not working' );

# --- a move back to any other column is not this rule --------------------------
#
# The owner anchored this to backlog deliberately: it is the one column every
# board has, so the rule needs no per-board configuration. A retreat that stops
# short of the queue is not the same statement about the work.

my $other = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card retreating only part way', author => 'ada',
);
$tira->record_move(
    project => $root, type => 'ticket', ref => $other->{ref}, column => 'implement', author => 'ada',
);
$tira->record_move(
    project => $root, type => 'ticket', ref => $other->{ref}, column => 'done', author => 'ada',
);
my $part_way = $tira->tasklist_add( project => $root, text => 'Still being worked', author => 'ada' );
$tira->tasklist_task_ref_link( project => $root, id => $part_way->{id}, refs => [ $other->{ref} ] );
$tira->tasklist_update( project => $root, id => $part_way->{id}, status => 'working' );

{
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $ignored or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    eval {
        Tira::CLI->run(
            command => 'record.move', tira => $tira,
            argv    => [ '--type', 'ticket', '--ref', $other->{ref},
                         '--column', 'implement', '--author', 'ada', '-o', 'toon' ],
        );
    };
    select $old;
}

is( status_of( $part_way->{id} ), 1,
    'a card retreating to a column that is not backlog leaves its tasks alone' );

# --- the browser move does it too -------------------------------------------
#
# TKT-452 drew the line: the gating half of a move stays CLI-only, because a
# human dragging a card is not an agent skipping a gate, but the bookkeeping
# half is not enforcement and has to happen either way or the card is left
# inaccurate for whoever looks at it next. Resetting a task that says somebody
# is working a card now sitting in the queue is bookkeeping by that test.
#
# Left out of the browser provider at first, so a card dragged back to backlog
# went on claiming its tasks were being worked - the fault this file is about,
# surviving on the path the owner is most likely to use.

my $dragged = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card dragged back in the browser', author => 'ada',
);
$tira->record_move(
    project => $root, type => 'ticket', ref => $dragged->{ref}, column => 'implement', author => 'ada',
);
my $dragged_task = $tira->tasklist_add( project => $root, text => 'Working the dragged card', author => 'ada' );
$tira->tasklist_task_ref_link( project => $root, id => $dragged_task->{id}, refs => [ $dragged->{ref} ] );
$tira->tasklist_update( project => $root, id => $dragged_task->{id}, status => 'working' );

my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
{
    open my $eh, '>', \my $ignored or die $!;
    local *STDERR = $eh;
    $providers{move}->( { ref => $dragged->{ref}, column => 'backlog', type => 'ticket', _signed_in => 'ada' } );
}

is( $tira->record_show( project => $root, type => 'ticket', ref => $dragged->{ref} )->{column},
    'backlog', 'the browser move put the card back in backlog' );
is( status_of( $dragged_task->{id} ), 0,
    'and reset its task too - the bookkeeping half of a move is not CLI-only, only the gating half is' );

# --- a reset that fails is said, not swallowed --------------------------------
#
# Written first as a bare eval whose failure left the task neither reset nor
# mentioned - the task would go on reading "working" and the move would report
# nothing about it, which is indistinguishable from there having been no task
# at all. That is the same silent skip the multi-ref rule above exists to
# avoid, one line lower in the same function.

my $doomed_card = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card whose task will not update', author => 'ada',
);
$tira->record_move(
    project => $root, type => 'ticket', ref => $doomed_card->{ref}, column => 'implement', author => 'ada',
);
my $doomed = $tira->tasklist_add( project => $root, text => 'A task that refuses to be reset', author => 'ada' );
$tira->tasklist_task_ref_link( project => $root, id => $doomed->{id}, refs => [ $doomed_card->{ref} ] );
$tira->tasklist_update( project => $root, id => $doomed->{id}, status => 'working' );

my $failed_said = '';
{
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \$failed_said or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    no warnings 'redefine';
    my $real = \&Tira::tasklist_update;
    local *Tira::tasklist_update = sub {
        my ( $self, %a ) = @_;
        die "the store said no\n" if ( $a{id} // '' ) eq $doomed->{id};
        return $real->( $self, %a );
    };
    eval {
        Tira::CLI->run(
            command => 'record.move', tira => $tira,
            argv    => [ '--type', 'ticket', '--ref', $doomed_card->{ref},
                         '--column', 'backlog', '--author', 'ada', '-o', 'toon' ],
        );
    };
    select $old;
}

like( $failed_said, qr/\Q$doomed->{id}\E/,
    'a task that could not be reset is named, not silently left claiming somebody is working it' );
like( $failed_said, qr/the store said no/,
    'and the reason is given, so the reader knows whether to retry it or fix something else' );
is( status_of( $doomed->{id} ), 1,
    'and it genuinely was not reset - the report is about a real failure, not a cosmetic line' );

done_testing();

__END__

=head1 NAME

t/408-a-task-still-working-on-a-card-that-went-back.t - a card returning to
backlog resets the tasklist items that say somebody is working it

=head1 DESCRIPTION

A backward move already resets required items between the destination and the
origin, keeping their proof (TKT-455) - the board understands that retreating
undoes claims of progress. Tasks were never part of that, so a card could sit
in the queue while its tasklist went on saying somebody was on it.

Anchored to C<backlog> because it is the default builtin column, a fix point
every board has, so the rule needs no per-board configuration.

Three decisions carry their own assertions. A done task is left alone, because
it records work that happened. The reset crosses TKT-537's session boundary
deliberately, since the tasks most needing reset on a multi-agent board belong
to another session and a boundary-respecting reset would do nothing in exactly
the case it exists for. And a task linked to more than one card is not reset
but B<is> named in the output - Q-088, where the owner chose visibility over a
silent skip, because a silent skip is indistinguishable from the feature being
broken.

=cut
