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

# The board every command here works on, named the one way there is.
# TKT-250.
$ENV{TIRA_HOME} = $root;
$tira->project_new(
    name => 'Asked', dir => $root, members => ['michael'], columns => ['Backlog, Doing'],
    sow_prefix => 'ASS', epic_prefix => 'ASE', ticket_prefix => 'AST',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Wire the importer' );
my $epic = $tira->create_record( project => $root, type => 'epic', title => 'An epic' );

# Asked by card reference alone: the reference already names the board.
my $first = $tira->question_add(
    project => $root, ref => $card->{ref}, text => 'Which credentials should this use?' );
is( $first->{id}, 'Q-001', 'the first question in the project is Q-001' );
is( $first->{status}, 'new', 'and starts as new' );
is( $first->{asked_at}, $tick, 'stamped when it was asked' );
ok( !defined $first->{answer}, 'with no answer yet' );

my $second = $tira->question_add(
    project => $root, ref => $card->{ref}, text => 'Is the staging bucket the right one?' );
is( $second->{id}, 'Q-002', 'the second is Q-002' );

# Every board, not just tickets.
is( $tira->question_add( project => $root, ref => $epic->{ref}, text => 'Scope?' )->{id},
    'Q-003', 'a question on the epic board continues the same project sequence' );

# A reference nobody owns is refused rather than guessed at.
eval { $tira->question_add( project => $root, ref => 'ZZZ-001', text => 'Nowhere' ) };
like( $@, qr/ZZZ-001/, 'a reference matching no board is refused' );

# Bad input is refused.
for my $case (
    [ { ref => $card->{ref} }, qr/text|question/i, 'a question with no text' ],
    [ { ref => $card->{ref}, text => '' }, qr/text|question/i, 'an empty question' ],
    [ { text => 'orphan' }, qr/reference/i, 'a question with no card' ],
) {
    my ( $args, $error, $label ) = @{$case};
    eval { $tira->question_add( project => $root, %{$args} ) };
    like( $@, $error, "$label is refused" );
}

# Answering.
$tick = '2026-08-09T11:00:00Z';
my $answered = $tira->question_answer(
    project => $root, ref => $card->{ref}, id => 'Q-001',
    text => 'Use the read-only service account.', author => 'michael' );
is( $answered->{status}, 'answered', 'answering makes it answered' );
is( $answered->{answer}{text}, 'Use the read-only service account.', 'the answer is kept verbatim' );
is( $answered->{answer}{answered_at}, $tick, 'the answer carries its own stamp' );
is( $answered->{asked_at}, '2026-08-09T09:00:00Z',
    'and the question stamp never changes, because it is when it was asked' );
ok( !defined $answered->{answer}{read_at}, 'nobody has read it yet' );

# Answering again rewords the answer: it stamps the answer, never the question.
$tick = '2026-08-09T11:30:00Z';
my $reworded = $tira->question_answer(
    project => $root, id => 'Q-001', text => 'Use the read-only account, not the admin one.' );
is( $reworded->{answer}{text}, 'Use the read-only account, not the admin one.',
    'answering again replaces the answer' );
is( $reworded->{answer}{updated_at}, $tick, 'and stamps when it was changed' );
is( $reworded->{answer}{answered_at}, '2026-08-09T11:00:00Z',
    'while when it was first answered stands' );
is( $reworded->{asked_at}, '2026-08-09T09:00:00Z',
    'and the question still says when it was asked' );

# Reading is what marks it read - the agent does nothing extra.
$tick = '2026-08-09T12:00:00Z';
my $listed = $tira->question_list( project => $root, ref => $card->{ref} );
is( scalar @{ $listed->{questions} }, 2, 'both questions are listed' );
is( $listed->{questions}[0]{answer}{read_at}, $tick, 'listing marks the answer read' );
# non-empty is the whole claim: the two lines below pin what it must name.
like( $listed->{instruction}, qr/\S/, 'the list tells the agent what to do next' );
like( $listed->{instruction}, qr/question\.mark/, 'naming the command that marks an answer' );
like( $listed->{instruction}, qr/question\.ask/, 'and the one that asks a new question' );

# Reading again must not keep rewriting the card.
my $before = $tira->record_show( project => $root, ref => $card->{ref} )->{last_updated};
$tick = '2026-08-09T13:00:00Z';
$tira->question_list( project => $root, ref => $card->{ref} );
is( $tira->record_show( project => $root, ref => $card->{ref} )->{last_updated}, $before,
    'a second read changes nothing, because there was nothing left to mark' );
is( $tira->question_list( project => $root, ref => $card->{ref} )->{questions}[0]{answer}{read_at},
    '2026-08-09T12:00:00Z', 'and the first read time stands' );

# The two marks.
my $marked = $tira->question_mark(
    project => $root, ref => $card->{ref}, id => 'Q-001', mark => 'ok' );
is( $marked->{answer}{mark}, 'ok', 'an answer can be marked ok' );
$marked = $tira->question_mark(
    project => $root, ref => $card->{ref}, id => 'Q-001', mark => 'not-ok' );
is( $marked->{answer}{mark}, 'not-ok', 'or not ok' );
eval { $tira->question_mark( project => $root, ref => $card->{ref}, id => 'Q-001', mark => 'maybe' ) };
like( $@, qr/ok/, 'and nothing else' );
eval { $tira->question_mark( project => $root, ref => $card->{ref}, id => 'Q-002', mark => 'ok' ) };
like( $@, qr/not been answered/i, 'an unanswered question cannot be marked' );

# Updating and removing.
is( $tira->question_update( project => $root, ref => $card->{ref}, id => 'Q-002',
        text => 'Is the staging bucket correct?' )->{text},
    'Is the staging bucket correct?', 'a question can be reworded' );
# Nothing is ever really deleted: discarding is an illusion, like the Discard
# column. The question stays, its answer stays under it, and the board draws it
# struck through.
ok( !Tira->can('question_remove'), 'there is no way to delete a question outright' );
my $discarded = $tira->question_discard( project => $root, ref => $card->{ref}, id => 'Q-002' );
is( $discarded->{status}, 'discarded', 'a question can be discarded' );
is( $discarded->{text}, 'Is the staging bucket correct?', 'and keeps its text' );
ok( $discarded->{discarded_at}, 'stamped when it was discarded' );
is( scalar @{ $tira->question_list( project => $root, ref => $card->{ref} )->{questions} }, 2,
    'it is still listed, because it still happened' );
eval { $tira->question_discard( project => $root, ref => $card->{ref}, id => 'Q-002' ) };
like( $@, qr/already discarded/, 'discarding twice says so' );
eval { $tira->question_answer( project => $root, ref => $card->{ref}, id => 'Q-002', text => 'x' ) };
like( $@, qr/discarded/, 'and a discarded question cannot be answered' );
eval { $tira->question_update( project => $root, ref => $card->{ref}, id => 'Q-404', text => 'x' ) };
like( $@, qr/Q-404/, 'touching one that is not there says which' );

# Filtering by status.
$tick = '2026-08-09T14:00:00Z';
$tira->question_add( project => $root, ref => $card->{ref}, text => 'A fresh one' );
my $new_only = $tira->question_list( project => $root, ref => $card->{ref}, status => 'new' );
is_deeply( [ map { $_->{status} } @{ $new_only->{questions} } ], ['new'],
    'new only returns the unanswered ones, not the discarded one' );
is_deeply(
    [ map { $_->{id} } @{ $tira->question_list(
        project => $root, ref => $card->{ref}, status => 'discarded' )->{questions} } ],
    ['Q-002'], 'and discarded can be asked for on its own' );
my $done_only = $tira->question_list( project => $root, ref => $card->{ref}, status => 'answered' );
is_deeply( [ map { $_->{status} } @{ $done_only->{questions} } ], ['answered'],
    'answered only returns answered' );
eval { $tira->question_list( project => $root, ref => $card->{ref}, status => 'follow-up' ) };
like( $@, qr/new, answered or discarded/i, 'and there is no follow-up status' );

# Filtering by time reads the answer stamp when there is one.
my $since = $tira->question_list(
    project => $root, ref => $card->{ref}, since => '2026-08-09T13:30:00Z' );
is_deeply( [ map { $_->{id} } @{ $since->{questions} } ], ['Q-004'],
    'only what has moved since then' );
$tick = '2026-08-09T15:00:00Z';
$tira->question_answer( project => $root, ref => $card->{ref}, id => 'Q-004', text => 'Yes' );
$since = $tira->question_list(
    project => $root, ref => $card->{ref}, since => '2026-08-09T14:30:00Z' );
is( scalar @{ $since->{questions} }, 1, 'a newly answered question shows up as newly changed' );

# Robustness: a board whose config cannot be read must not stop a reference on
# another board resolving, and a stamp that cannot be parsed must not be
# treated as new.
{
    my $broken = File::Spec->catdir( $tmp, 'broken' );
    my $other = Tira->new( clock => sub {$tick} );
    $other->project_new( name => 'Broken', dir => $broken, columns => ['Backlog, Doing'],
        sow_prefix => 'BKS', epic_prefix => 'BKE', ticket_prefix => 'BKT' );
    my $only = $other->create_record( project => $broken, type => 'ticket', title => 'Still reachable' );
    unlink File::Spec->catfile( $broken, '.tira', 'sow', 'config.yml' ) or die $!;
    is( $other->question_add( project => $broken, ref => $only->{ref}, text => 'Reachable?' )->{id},
        'Q-001', 'a board with an unreadable config does not block the others' );
}

{
    my $path = File::Spec->catfile( $root, '.tira', 'ticket', 'backlog', $card->{ref} . '.json' );
    my $body = do { open my $fh, '<:raw', $path or die $!; local $/; <$fh> };
    my $record = decode_json($body);
    $record->{questions}[0]{asked_at} = 'not a date at all';
    $record->{questions}[0]{answer} = undef;
    open my $out, '>:raw', $path or die $!;
    print {$out} Cpanel::JSON::XS->new->canonical->pretty->encode($record);
    close $out;
    my $filtered = $tira->question_list(
        project => $root, ref => $card->{ref}, since => '2020-01-01T00:00:00Z' );
    ok( !grep( { $_->{id} eq 'Q-001' } @{ $filtered->{questions} } ),
        'a question whose stamp cannot be read is left out rather than reported as recent' );
}

# A question reference is enough on its own: nobody has to say which card.
is( $tira->question_answer( project => $root, id => 'Q-003', text => 'The whole importer.' )->{status},
    'answered', 'a question on another board is reached by its reference alone' );
is( $tira->question_list( project => $root, ref => $epic->{ref} )->{questions}[0]{answer}{text},
    'The whole importer.', 'and the answer landed on the right card' );

# The CLI surface, by reference with no board argument.
my ( $status, $out ) = run_cli( 'question.ask', '--ref', $card->{ref}, '--text', 'From the CLI', '-o', 'json' );
is( $status, 0, 'the CLI asks a question' );
is( decode_json($out)->{status}, 'new', 'and it starts new' );

( $status, $out ) = run_cli( 'question.list', '--ref', $card->{ref}, '-o', 'json' );
is( $status, 0, 'the CLI lists them' );
ok( decode_json($out)->{instruction}, 'with the next-step instruction' );

( $status, $out ) = run_cli( 'question.answer', '--id', 'Q-005', '--text', 'Answered from the CLI', '-o', 'json' );
is( $status, 0, 'the CLI answers one' );

( $status, $out ) = run_cli( 'question.mark', '--id', 'Q-005', '--mark', 'ok', '-o', 'json' );
is( $status, 0, 'the CLI marks one' );

( $status, $out ) = run_cli( 'question.ask', '--ref', 'ZZZ-9', '--text', 'x', '-o', 'json' );
is( $status, 2, 'an unknown reference exits 2' );

( $status, $out ) = run_cli( 'question.list', '--help' );
is( $status, 0, 'the command offers help' );
like( $out, qr/Usage/i,
    'and prints some, so the denial below is about help that exists' );
unlike( $out, qr/--project|TIRA_HOME/, 'help never discloses project selection' );

done_testing;

__END__

=head1 NAME

57-questions.t - questions on cards

=head1 DESCRIPTION

Replaces the open-decision file every agent kept in its own format. An
agent asks against a card by reference alone, because the reference
already names the board. Status is derived from whether there is an
answer, so it cannot drift. Listing the answers is what marks them
read, and writes only when there is something to mark. The mark on an
answer is separate from having read it, and a cross settles nothing on
its own. The question's own stamp never changes, and the time filter
reads the answer's stamp when there is an answer, so an agent catching
up sees new answers as well as new questions.

=cut
