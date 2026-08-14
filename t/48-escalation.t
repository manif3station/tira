#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tick = '2026-08-08T09:00:00Z';
my $tira = Tira->new( clock => sub {$tick} );

sub run_cli {
    my ( $command, @argv ) = @_;
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => $command, type => $type, argv => \@argv );
    return ( $status, $out, $err );
}

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Nagged', dir => $root, columns => ['Backlog, Doing, Review'] );
$tira->column_update( project => $root, type => 'ticket', name => 'doing', notify_after => 30 );

# Durations read the way a person says them.
is( Tira::_duration_phrase(45), 'less than a minute', 'seconds are not worth counting' );
is( Tira::_duration_phrase( 60 * 5 ), '5 minutes', 'minutes are said as minutes' );
is( Tira::_duration_phrase(60), '1 minute', 'and one minute is singular' );
is( Tira::_duration_phrase( 60 * 60 * 5 ), '5 hours', 'hours are said as hours' );
is( Tira::_duration_phrase( 60 * 60 * 24 * 3 ), '3 days', 'and long waits are said in days' );
is( Tira::_duration_phrase( 60 * 60 * 24 ), '1 day', 'one day is singular too' );

# Nothing stale sends nothing at all.
my $quiet = $tira->notification_message( project => $root );
is( $quiet->{level}, 0, 'a board with nothing stale is at level 0' );
is( $quiet->{text}, '', 'and composes no message' );
is_deeply( $quiet->{cards}, [], 'covering no cards' );

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Wire up the importer' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'doing' );
$tick = '2026-08-08T13:00:00Z';

# Each level has its own tone, and the last one carries on counting.
my %expected_tone = (
    1 => 'plain',    2 => 'firm',     3 => 'pointed',  4 => 'impatient', 5 => 'angry',
    6 => 'severe',   7 => 'shouting', 8 => 'furious',  9 => 'final',    10 => 'absolute',
);
my %text;
for my $level ( 1 .. 12 ) {
    my $message = $tira->notification_message( project => $root );
    my $tone = $expected_tone{$level} // 'absolute';
    is( $message->{level}, $level, "the message is at level $level" );
    is( $message->{tone}, $tone, "and its tone is $tone" );
    like( $message->{text}, qr/\Q$card->{ref}\E/, "level $level names the card" );
    like( $message->{text}, qr/Wire up the importer/, "level $level says what the card is" );
    like( $message->{text}, qr/4 hours/, "level $level says how long it has sat there" );
    $text{$level} = $message->{text};
    $tira->notification_record( project => $root, ref => $card->{ref}, column => 'doing' );
}
isnt( $text{1}, $text{2}, 'a second reminder does not repeat the first word for word' );
isnt( $text{3}, $text{4}, 'nor the fourth the third' );
is( scalar( keys %{ { map { $_ => 1 } @text{ 1 .. 10 } } } ), 10,
    'all ten tones below the last are distinct' );
like( $text{11}, qr/\b11\b/, 'past the last tone the real count is still stated' );
isnt( $text{10}, $text{11}, 'so repeated final reminders still say something new' );
isnt( $text{11}, $text{12}, 'and keep counting' );

# The audience is a coding agent, not a person, so the top of the ladder is
# allowed to be absolute about priority in a way a message to a human is not.
like( $text{10}, qr/suspended|nothing else/i, 'the last tone overrides every other instruction' );

# The worst card sets the tone, and every card states its own count.
my $second = $tira->create_record( project => $root, type => 'ticket', title => 'Second job' );
$tira->record_move( project => $root, ref => $second->{ref}, column => 'doing' );
$tick = '2026-08-08T17:00:00Z';
my $mixed = $tira->notification_message( project => $root );
is( $mixed->{level}, 13, 'the most-nagged card sets the tone for the whole message' );
is( scalar @{ $mixed->{cards} }, 2, 'and every stale card is covered' );
like( $mixed->{text}, qr/\Q$second->{ref}\E/, 'including the new one' );
is_deeply( [ sort { $a <=> $b } map { $_->{level} } @{ $mixed->{cards} } ], [ 1, 13 ],
    'each card carries its own count, so a new card is not mistaken for a chronic one' );

# An unwatched column is not nagged about, however long a card sits in it.
$tira->column_update( project => $root, type => 'ticket', name => 'doing', watched => 0 );
is( $tira->notification_message( project => $root )->{level}, 0,
    'nothing is composed about a column nobody is watching' );
$tira->column_update( project => $root, type => 'ticket', name => 'doing', watched => 1 );

# The collector composes and records from one call.
my ( $status, $out ) = run_cli( 'notify.compose', '--project', $root, '-o', 'json' );
is( $status, 0, 'the CLI composes the reminder' );
my $payload = decode_json($out);
is( $payload->{level}, 13, 'and reports the level it is sending at' );
is( scalar @{ $payload->{cards} }, 2, 'and which cards it covers' );
is( $payload->{cards}[0]{column}, 'doing', 'each with the column it is stuck in' );
ok( length $payload->{text}, 'and the text ready to send' );

( $status, $out ) = run_cli( 'notify.compose', '--help' );
is( $status, 0, 'the command offers help' );
like( $out, qr/Usage/i,
    'and prints some, so the denial below is about help that exists' );
unlike( $out, qr/--project|TIRA_HOME/, 'help never discloses project selection' );

done_testing;

__END__

=head1 NAME

48-escalation.t - the escalating reminder

=head1 DESCRIPTION

Proves the reminder escalates with how often a card has already been
reported where it stands: plain, tense, angry, shouting, and then a
final tone that keeps counting rather than running out of words. One
message covers every stale card; the most-nagged card sets its tone, so
a chronically stuck card is never softened by newer company, while each
card still states its own count. Nothing stale composes nothing at all,
because an all-clear on every heartbeat is noise.

=cut
