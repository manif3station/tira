#!/usr/bin/env perl
# The work log says who changed the card.
#
# Developer-Dashboard's reminder collector ran "claude -p --resume <session>"
# every fifteen minutes against the session an agent was working in. So every
# quarter hour a headless copy read a reminder that a card was in Todo and moved
# it to Planning to be helpful; the agent moved it back, and it moved it again.
# The history recorded those moves with no author, so from the record the card
# appeared to move by itself. They read the reverted move as a write that had
# not persisted, told their owner so, and were wrong. It took two days and a
# phone screenshot to find.
#
# Their first suggestion - a reminder must not be able to write - belongs to
# Developer-Dashboard. The second is ours: attribute every write.
#
# Running one card through the ordinary commands showed it was wider than the
# card they saw. Only four methods ever set the journal's author -
# record_update, record_move, conversation_add and comment_add - and every
# record write goes through one function that stamps whatever happens to be
# there. So the checklist, the gates, the evidence and the assignee were all
# written by nobody.
#
# Worse than an oversight: gate.add and evidence.add TAKE an author, store it
# inside the entry, and did not use it for the work log. The name was collected
# and then not used for the one thing the log exists to answer.
#
# Fixed where identity is known. The command layer already resolves who is
# speaking - from --author, or from TIRA_AUTHOR said once rather than on every
# command - so it sets it for whatever runs next, and the methods that validate
# it themselves still do.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-14T07:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Traceable', dir => $root, members => [ 'michael', 'ada' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'TRS', epic_prefix => 'TRE', ticket_prefix => 'TRT',
);

sub run {
    my (@argv) = @_;
    my $command = shift @argv;
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => $command, type => $type, tira => $tira,
            argv => [ @argv ] ) };
    };
    return ( $status, $out, $err );
}

sub authors_of {
    my ($ref) = @_;
    my %by_field;
    for my $write ( @{ $tira->history_list( project => $root, ref => $ref ) } ) {
        $by_field{ $write->{field} // '' } = $write->{author};
    }
    return \%by_field;
}

my ($status) = run( 'ticket.create', '--title', 'Who touched this', '--author', 'michael' );
is( $status, 0, 'a card is raised' );
my ($ref) = @{ $tira->record_list( project => $root, type => 'ticket', refs_only => 1 ) };
$ref = ref $ref ? $ref->{ref} : $ref;

# --- everything an agent does to a card, each saying who it is ------------------

is( ( run( 'checklist.add', '--ref', $ref, '--item', 'a step', '--status', 'todo',
        '--author', 'michael' ) )[0], 0, 'a checklist item is added' );
is( ( run( 'gate.add', '--ref', $ref, '--author', 'michael', '--gate', 'a gate',
        '--result', 'pass', '--details', 'it passed' ) )[0], 0, 'a gate is recorded' );
is( ( run( 'evidence.add', '--ref', $ref, '--author', 'michael',
        '--summary', 'the measurement, taken twice' ) )[0], 0, 'evidence is attached' );
is( ( run( 'assign.set', '--ref', $ref, '--person', 'ada', '--author', 'michael' ) )[0], 0,
    'and somebody takes it' );

my $wrote = authors_of($ref);
is( $wrote->{checklist},        'michael', 'the work log says who added the checklist item' );
is( $wrote->{gate_passing_log}, 'michael',
    'and who recorded the gate - the name it already stored inside the entry and did not use here' );
is( $wrote->{evidence},         'michael', 'and who attached the evidence' );
is( $wrote->{assignee},         'michael', 'and who assigned it' );

# --- said once rather than on every command --------------------------------------
#
# How an unattended writer becomes attributable: it says who it is once, in the
# environment, and everything it does afterwards carries the name. That is the
# half of their report that belongs to this side.

{
    local $ENV{TIRA_AUTHOR} = 'ada';
    is( ( run( 'ticket.move', '--ref', $ref, '--column', 'implement' ) )[0], 0,
        'a card is moved by somebody who named themselves once' );
}
is( authors_of($ref)->{column}, 'ada',
    'and the move carries their name, where the reported card moved by nobody' );

# --- a name the board does not know is not recorded --------------------------------
#
# A log that will write down any name is not evidence. The reported failure was
# a write nobody could account for; a write attributed to somebody who does not
# exist would be worse, because it reads as accounted for.

{
    local $ENV{TIRA_AUTHOR} = 'a-ghost';
    run( 'ticket.update', '--ref', $ref, '--description', 'written by a ghost' );
}
my $ghost = authors_of($ref)->{description};
ok( !defined $ghost || $ghost ne 'a-ghost',
    'a name the board does not know is never written into the log as though it were somebody' );

done_testing;

__END__

=head1 NAME

151-who-changed-this.t - the work log says who changed the card

=head1 DESCRIPTION

Every record write goes through one function that stamps the journal with
whatever author happens to be set, and only four methods ever set it. So the
checklist, the gates, the evidence and the assignee were all written by nobody -
and C<gate.add> and C<evidence.add> collected an author, stored it inside the
entry, and did not use it for the log.

A project spent two days on a card that appeared to move by itself, because a
headless agent resuming their session moved it every fifteen minutes and the
history could not say so. The command layer now sets the author for whatever
runs next, from C<--author> or from C<TIRA_AUTHOR> said once, and a name the
board does not know is not recorded.

=cut
