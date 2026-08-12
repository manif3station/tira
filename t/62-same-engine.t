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
my $tick = '2026-08-09T09:00:00Z';
my $tira = Tira->new( clock => sub {$tick} );

sub cli {
    my (@argv) = @_;
    my $command = shift @argv;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;

    # The same engine both sides, or this compares two clocks rather than two
    # interfaces - which is what it caught the first time it ran.
    my $status = Tira::CLI->run( command => $command, argv => \@argv, tira => $tira );
    return ( $status, $out );
}

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Same', dir => $root, columns => ['Backlog, Doing'],
    sow_prefix => 'SMS', epic_prefix => 'SME', ticket_prefix => 'SMT' );
$tira->column_update( project => $root, type => 'ticket', name => 'doing', notify_after => 30 );

my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );

# Two cards, identical in every way. One is answered from the command line, the
# other from the board. Whatever the interface, the same thing must happen
# underneath - otherwise a trigger fires for one and not the other.
my %ref;
for my $side (qw(cli board)) {
    my $card = $tira->create_record( project => $root, type => 'ticket', title => "Work $side" );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'doing' );
    $ref{$side} = $card->{ref};
}
my %question = map {
    $_ => $tira->question_add(
        project => $root, ref => $ref{$_}, text => 'Which store?',
        reason => 'Two are configured.', options => [ 'Staging', 'Live' ] )->{id}
} qw(cli board);

# Both cards are now blocked, by either route.
$tick = '2026-08-09T13:00:00Z';
is_deeply( $tira->dwell_list( project => $root, stale => 1 ), [],
    'a question blocks the reminder whichever way it was asked' );

# Answer one from each side.
my ( $status ) = cli( 'question.answer', '--project', $root,
    '--id', $question{cli}, '--text', 'Staging', '-o', 'json' );
is( $status, 0, 'the command line answers' );
ok( decode_json( $providers{question_answer}->(
        { id => $question{board}, text => 'Staging' } ) )->{ok},
    'and so does the board' );

# Every consequence must be identical: status, the answer itself, the stamp,
# whether the card is still waiting, and whether it is chased again.
for my $field (qw(status)) {
    my %got = map {
        $_ => $tira->question_list( project => $root, ref => $ref{$_} )->{questions}[0]{$field}
    } qw(cli board);
    is( $got{board}, $got{cli}, "the $field is the same either way" );
}
my %answer = map {
    $_ => $tira->question_list( project => $root, ref => $ref{$_} )->{questions}[0]{answer}
} qw(cli board);
is( $answer{board}{text}, $answer{cli}{text}, 'the answer text is the same' );
is( $answer{board}{answered_at}, $answer{cli}{answered_at}, 'and stamped the same way' );

# The blocking, the clock and the all-clear are engine behaviour, so they must
# have fired for both - this is the whole point of one path underneath.
is_deeply(
    [ sort map { $_->{ref} } @{ $tira->clearance_list( project => $root ) } ],
    [ sort values %ref ],
    'both cards owe an all-clear, so answering from the board is not a lesser answer' );

$tick = '2026-08-09T14:00:00Z';
is_deeply(
    [ sort map { $_->{ref} } @{ $tira->dwell_list( project => $root, stale => 1 ) } ],
    [ sort values %ref ],
    'and both are chased again from the moment they were answered' );

# Marking, the same way.
( $status ) = cli( 'question.mark', '--project', $root,
    '--id', $question{cli}, '--mark', 'ok', '-o', 'json' );
is( $status, 0, 'the command line marks' );
ok( decode_json( $providers{question_mark}->( { id => $question{board}, mark => 'ok' } ) )->{ok},
    'and so does the board' );
my %waiting;
for my $side (qw(cli board)) {
    my $board = $tira->dashboard( project => $root, type => 'ticket', summary => 1, with_questions => 1 );
    for my $column ( values %{ $board->{ticket} } ) {
        $waiting{$side} = $_->{waiting} for grep { $_->{ref} eq $ref{$side} } @{$column};
    }
}
is( $waiting{board}, $waiting{cli}, 'the card colour is decided the same way for both' );
is( $waiting{board}, 0, 'and both are settled' );

# The board cannot reach past the engine's rules either.
my $error = eval { $providers{question_mark}->( { id => $question{board}, mark => 'maybe' } ); 1 }
  ? '' : $@;
like( $error, qr/ok/, 'an invalid mark is refused through the board exactly as on the command line' );

done_testing;

__END__

=head1 NAME

62-same-engine.t - the board and the command line are one path underneath

=head1 DESCRIPTION

The dashboard is an interface, not a second implementation: everything
done on it goes through the same engine subroutines the command line
calls. Proves it by doing the same work from both sides and comparing
every consequence: the stored answer, its stamp, whether the card is
still waiting, whether the reminder is owed an all-clear, and when the
card is chased again. If the board took a shortcut, one of those
triggers would fire for one card and not the other.

=cut
