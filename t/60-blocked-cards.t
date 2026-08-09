#!/usr/bin/env perl

use strict;
use warnings;

use File::Path ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tick = '2026-08-09T09:00:00Z';
my $tira = Tira->new( clock => sub {$tick} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Blocked', dir => $root, columns => ['Backlog, Doing'],
    sow_prefix => 'BLS', epic_prefix => 'BLE', ticket_prefix => 'BLT' );
$tira->column_update( project => $root, type => 'ticket', name => 'doing', notify_after => 30 );

my $asked = $tira->create_record( project => $root, type => 'ticket', title => 'Blocked on you' );
my $plain = $tira->create_record( project => $root, type => 'ticket', title => 'Just slow' );
$tira->record_move( project => $root, ref => $asked->{ref}, column => 'doing' );
$tira->record_move( project => $root, ref => $plain->{ref}, column => 'doing' );

sub stale_refs {
    return [ map { $_->{ref} } @{ $tira->dwell_list( project => $root, stale => 1 ) } ];
}

# Both are overdue on the clock alone.
$tick = '2026-08-09T13:00:00Z';
is_deeply( stale_refs(), [ sort $asked->{ref}, $plain->{ref} ], 'both cards are overdue to begin with' );

# Asking a question takes the card out of the agent's hands.
my $question = $tira->question_add( project => $root, ref => $asked->{ref}, text => 'Which bucket?' );
is_deeply( stale_refs(), [ $plain->{ref} ],
    'a card waiting on an answer is not chased, because it is not the agent holding it' );

# Days pass with no answer. Still not the agent's fault.
$tick = '2026-08-12T13:00:00Z';
is_deeply( stale_refs(), [ $plain->{ref} ], 'however long it waits' );

# Answering hands it back - and the clock starts from the answer, not the move.
$tira->question_answer( project => $root, id => $question->{id}, text => 'The staging one.' );
is_deeply( stale_refs(), [ $plain->{ref} ],
    'the moment it is answered it is not instantly overdue for the days you took' );
$tick = '2026-08-12T14:00:00Z';
is_deeply( stale_refs(), [ sort $asked->{ref}, $plain->{ref} ],
    'it becomes overdue again only once it has sat unattended since the answer' );

# Marking is the agent's business and has nothing to do with being chased.
$tira->question_list( project => $root, ref => $asked->{ref} );
is_deeply( stale_refs(), [ sort $asked->{ref}, $plain->{ref} ],
    'an agent cannot dodge the reminders by never marking the answer' );

# The all-clear itself: owed once, then not again.
my $owed = $tira->clearance_list( project => $root );
is_deeply( [ map { $_->{ref} } @{$owed} ], [ $asked->{ref} ],
    'an all-clear is owed for the card whose questions are all answered' );
is( $owed->[0]{title}, 'Blocked on you', 'and says which card it is' );
ok( !grep( { $_->{ref} eq $plain->{ref} } @{$owed} ), 'a card nobody asked about is owed nothing' );

$tira->notification_record(
    project => $root, ref => $asked->{ref}, column => 'doing', kind => 'cleared' );
is_deeply( $tira->clearance_list( project => $root ), [],
    'once told, the agent is not told again' );

# Escalation starts again, because the agent was blocked rather than idle.
$tira->notification_record( project => $root, ref => $asked->{ref}, column => 'doing' );
$tira->notification_record( project => $root, ref => $asked->{ref}, column => 'doing' );
is( $tira->notification_level( project => $root, ref => $asked->{ref}, column => 'doing' ), 2,
    'the card has been chased twice' );
$tira->notification_record(
    project => $root, ref => $asked->{ref}, column => 'doing', kind => 'cleared' );
is( $tira->notification_level( project => $root, ref => $asked->{ref}, column => 'doing' ), 0,
    'an all-clear resets the count, so the next reminder is level one again' );
$tira->notification_record( project => $root, ref => $asked->{ref}, column => 'doing' );
is( $tira->notification_level( project => $root, ref => $asked->{ref}, column => 'doing' ), 1,
    'and it really does start at one' );

# New question, new answer, new all-clear.
$tick = '2026-08-12T15:00:00Z';
my $again = $tira->question_add( project => $root, ref => $asked->{ref}, text => 'And this?' );
is_deeply( $tira->clearance_list( project => $root ), [],
    'a fresh unanswered question owes no all-clear yet' );
is_deeply( stale_refs(), [ $plain->{ref} ], 'and blocks the card again' );
$tira->question_answer( project => $root, id => $again->{id}, text => 'Yes.' );
is_deeply( [ map { $_->{ref} } @{ $tira->clearance_list( project => $root ) } ], [ $asked->{ref} ],
    'answering it owes a fresh all-clear' );

# It reaches the message the collector actually sends.
$tick = '2026-08-12T18:00:00Z';
my $message = $tira->notification_message( project => $root );
like( $message->{text}, qr/back with you/, 'the composed message carries the all-clear' );
like( $message->{text}, qr/\Q$asked->{ref}\E/, 'naming the card' );
is_deeply( [ map { $_->{ref} } @{ $message->{cleared} } ], [ $asked->{ref} ],
    'and reports it separately so the collector can record it' );

# A discarded question blocks nothing.
my $third = $tira->create_record( project => $root, type => 'ticket', title => 'Set aside' );
$tira->record_move( project => $root, ref => $third->{ref}, column => 'doing' );
my $dropped = $tira->question_add( project => $root, ref => $third->{ref}, text => 'Never mind' );
$tira->question_discard( project => $root, id => $dropped->{id} );
$tick = '2026-08-12T19:00:00Z';
ok( scalar( grep { $_ eq $third->{ref} } @{ stale_refs() } ),
    'a card whose only question was set aside is chased like any other' );

# A database written before all-clears existed must keep working: the owner
# should not have to start his notification history again.
{
    my $old = File::Spec->catdir( $tmp, 'legacy' );
    $tira->project_new( name => 'Legacy', dir => $old, columns => ['Backlog, Doing'],
        sow_prefix => 'LGS', epic_prefix => 'LGE', ticket_prefix => 'LGT' );
    my $db = File::Spec->catfile( $old, '.tira', 'notification.db' );
    require DBI;
    my $dbh = DBI->connect( "dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 } );
    $dbh->do( 'CREATE TABLE notifications (id INTEGER PRIMARY KEY AUTOINCREMENT, '
          . 'ref TEXT NOT NULL, column_name TEXT NOT NULL, sent_at TEXT NOT NULL)' );
    $dbh->do( "INSERT INTO notifications (ref, column_name, sent_at) VALUES "
          . "('LGT-001', 'doing', '2026-08-01T09:00:00Z')" );
    $dbh->disconnect;

    is( $tira->notification_level( project => $old, ref => 'LGT-001', column => 'doing' ), 1,
        'a database written before this release still reports its history' );
    $tira->notification_record( project => $old, ref => 'LGT-001', column => 'doing' );
    is( $tira->notification_level( project => $old, ref => 'LGT-001', column => 'doing' ), 2,
        'and still counts, with the old rows treated as the reminders they were' );
    $tira->notification_record(
        project => $old, ref => 'LGT-001', column => 'doing', kind => 'cleared' );
    is( $tira->notification_level( project => $old, ref => 'LGT-001', column => 'doing' ), 0,
        'and an all-clear works against it, so nothing had to be thrown away' );
}

# A project missing a board directory entirely must not stop the others being
# read: half a project is still worth reporting on.
{
    my $partial = File::Spec->catdir( $tmp, 'partial' );
    $tira->project_new( name => 'Partial', dir => $partial, columns => ['Backlog, Doing'],
        sow_prefix => 'PTS', epic_prefix => 'PTE', ticket_prefix => 'PTT' );
    my $card = $tira->create_record( project => $partial, type => 'ticket', title => 'Only one' );
    my $q = $tira->question_add( project => $partial, ref => $card->{ref}, text => 'Well?' );
    $tira->question_answer( project => $partial, id => $q->{id}, text => 'Yes.' );
    File::Path::remove_tree( File::Spec->catdir( $partial, '.tira', 'sow' ) );
    is_deeply( [ map { $_->{ref} } @{ $tira->clearance_list( project => $partial ) } ],
        [ $card->{ref} ], 'a missing board does not stop the rest of the project being read' );
}

done_testing;

__END__

=head1 NAME

60-blocked-cards.t - DD-475 not chasing an agent for a card waiting on the owner

=head1 DESCRIPTION

While a card has a question nobody has answered it is in the owner's
hands, not the agent's, so chasing the agent is chasing the wrong
person. Proves such a card is never reported as stale however long it
waits, that answering hands it back with the clock running from the
answer rather than the original move, that escalation restarts at one
because the agent was blocked rather than idle, and that an all-clear
is owed once per round of questions. Marking the answers is the agent's
own business and cannot be used to dodge the reminders.

=cut
