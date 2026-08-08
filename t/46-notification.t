#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tick = '2026-08-08T09:00:00Z';
my $tira = Tira->new( clock => sub {$tick} );

sub run_cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => $command, argv => \@argv );
    return ( $status, $out, $err );
}

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Notify', dir => $root, columns => ['Backlog, Doing, Review'] );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Watched work' );
my $db = File::Spec->catfile( $root, '.tira', 'notification.db' );

# Asking costs nothing and leaves nothing behind.
is( $tira->notification_level( project => $root, ref => $card->{ref}, column => 'doing' ), 0,
    'a card that has never been reported is at level 0' );
is_deeply( $tira->notification_list( project => $root ), [],
    'a project that has never notified has an empty history' );
ok( !-e $db, 'asking about history creates no database file' );

# Escalation counts itself.
my $first = $tira->notification_record( project => $root, ref => $card->{ref}, column => 'doing' );
is( $first->{level}, 1, 'the first notification for a card in a column is level 1' );
is( $first->{at}, $tick, 'the notification is stamped with the time it was sent' );
ok( -e $db, 'the first recorded notification creates the database' );
$tick = '2026-08-08T10:00:00Z';
is( $tira->notification_record( project => $root, ref => $card->{ref}, column => 'doing' )->{level},
    2, 'reporting the same card in the same column again escalates to level 2' );
is( $tira->notification_record( project => $root, ref => $card->{ref}, column => 'doing' )->{level},
    3, 'and again to level 3' );
is( $tira->notification_level( project => $root, ref => $card->{ref}, column => 'doing' ), 3,
    'the level is readable without recording anything' );

# A move resets escalation for free, because the rows carry the column.
is( $tira->notification_record( project => $root, ref => $card->{ref}, column => 'review' )->{level},
    1, 'the same card in a different column starts again at level 1' );
is( $tira->notification_level( project => $root, ref => $card->{ref}, column => 'doing' ), 3,
    'the history of the column it left is untouched' );

# One message covers many cards, so many references record together.
my $second = $tira->create_record( project => $root, type => 'ticket', title => 'More work' );
my $third = $tira->create_record( project => $root, type => 'epic', title => 'An epic' );
my $batch = $tira->notification_record(
    project => $root, ref => [ $second->{ref}, $third->{ref} ], column => 'doing',
);
is( scalar @{$batch}, 2, 'several references record in one call' );
is_deeply( [ map { $_->{level} } @{$batch} ], [ 1, 1 ], 'each reference gets its own level' );

# History reads back in order and filters.
my $history = $tira->notification_list( project => $root );
is( scalar @{$history}, 6, 'every notification is kept' );
is( $history->[0]{ref}, $card->{ref}, 'history is returned in the order it was written' );
is( $history->[0]{column}, 'doing', 'each row records the column the card was sitting in' );
is( $history->[0]{at}, '2026-08-08T09:00:00Z', 'each row records when it was sent' );
is( scalar @{ $tira->notification_list( project => $root, ref => $card->{ref} ) }, 4,
    'history filters by reference' );

# Bad input is refused and writes nothing.
for my $case (
    [ { column => 'doing' }, qr/reference/i, 'a missing reference' ],
    [ { ref => '', column => 'doing' }, qr/reference/i, 'an empty reference' ],
    [ { ref => $card->{ref} }, qr/column/i, 'a missing column' ],
    [ { ref => $card->{ref}, column => '' }, qr/column/i, 'an empty column' ],
) {
    my ( $args, $error, $label ) = @{$case};
    eval { $tira->notification_record( project => $root, %{$args} ) };
    like( $@, $error, "$label is refused" );
}
is( scalar @{ $tira->notification_list( project => $root ) }, 6,
    'nothing was written by any refused call' );

# A batch is all or nothing.
eval {
    $tira->notification_record(
        project => $root, ref => [ $second->{ref}, '' ], column => 'doing',
    );
};
like( $@, qr/reference/i, 'one bad reference refuses the whole batch' );
is( scalar @{ $tira->notification_list( project => $root ) }, 6,
    'the refused batch left no rows behind, not even the good one' );

# The collector builds its whole message from one call.
$tick = '2026-08-08T09:30:00Z';
$tira->record_move( project => $root, ref => $second->{ref}, column => 'doing' );
$tira->column_update( project => $root, type => 'ticket', name => 'doing', notify_after => 5 );
$tick = '2026-08-08T11:00:00Z';
my $stale = $tira->dwell_list( project => $root, stale => 1, with_level => 1 );
is( scalar @{$stale}, 1, 'one card is past its column limit' );
is( $stale->[0]{ref}, $second->{ref}, 'and it is the card that moved' );
is( $stale->[0]{level}, 1, 'the stale card carries the level it has already reached' );

# When SQLite is unavailable the message names SQLite, not a Perl module.
{
    no warnings 'redefine';
    local *Tira::_sqlite_available = sub { 0 };
    eval { $tira->notification_record( project => $root, ref => $card->{ref}, column => 'doing' ) };
    my $error = $@;
    like( $error, qr/SQLite/, 'the error names SQLite' );
    like( $error, qr/install/i, 'and says to install it' );
    unlike( $error, qr/\@INC|BEGIN failed|Can't locate/,
        'and never leaks a Perl module load failure at the reader' );
}

# The CLI surface.
my ( $status, $out ) = run_cli( 'notify.record',
    '--project', $root, '--ref', $card->{ref}, '--column', 'doing', '-o', 'json' );
is( $status, 0, 'the CLI records a notification' );
is( decode_json($out)->[0]{level}, 4, 'and reports the level it reached' );

( $status, $out ) = run_cli( 'notify.list', '--project', $root, '--ref', $card->{ref}, '-o', 'json' );
is( $status, 0, 'the CLI lists history' );
is( scalar @{ decode_json($out) }, 5, 'the filtered history is complete' );

( $status, $out ) = run_cli( 'notify.record', '--project', $root, '--column', 'doing', '-o', 'json' );
is( $status, 2, 'a missing reference exits 2' );

( $status, $out ) = run_cli( 'notify.list', '--help' );
is( $status, 0, 'the command offers help' );
unlike( $out, qr/--project|TIRA_HOME/, 'help never discloses project selection' );

( $status, $out ) = run_cli( 'ticket.list', '--project', $root, '--with-level', '-o', 'json' );
is( $status, 2, 'with-level is refused on commands it does not belong to' );

done_testing;

__END__

=head1 NAME

46-notification.t - DD-460 notification history and escalation counting

=head1 DESCRIPTION

Proves that the escalation level is derived rather than stored: one row
per delivered notification in a SQLite database beside the project
file, and the level is how many rows that card already has in the
column it is sitting in. A move therefore resets escalation for free,
because rows written afterwards carry a different column name and the
card is never rewritten at all. Reading creates nothing, a batch is all
or nothing, and when SQLite is not installed the reader is told that in
those words rather than being shown a module load failure.

=cut
