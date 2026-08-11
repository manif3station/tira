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
my $tira = Tira->new( clock => sub { '2026-08-10T09:00:00Z' } );

sub cli {
    my (@argv) = @_;
    my $command = shift @argv;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => $command, argv => \@argv, tira => $tira );
    return ( $status, $out, $err );
}

sub file_at {
    my ( $name, $bytes ) = @_;
    my $path = File::Spec->catfile( $tmp, $name );
    open my $fh, '>:raw', $path or die $!;
    print {$fh} $bytes;
    close $fh;
    return $path;
}

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Evidence', dir => $root, members => ['ada'], columns => ['Backlog, Doing'],
    sow_prefix => 'EVS', epic_prefix => 'EVE', ticket_prefix => 'EVT' );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Needs evidence' );

# The agent asks and hangs its evidence on the question.
my $first = $tira->question_add( project => $root, ref => $card->{ref}, text => 'Which of these?' );
$tira->question_attach( project => $root, id => $first->{id}, file => file_at( 'screen.png', 'PNG-one' ) );
my $with_two = $tira->question_attach(
    project => $root, id => $first->{id}, file => file_at( 'trace.log', 'a trace' ) );
is( scalar @{ $with_two->{attachments} }, 2, 'a question carries the evidence the agent hung on it' );
is( $with_two->{attachments}[0]{original_filename}, 'screen.png', 'each keeping its name' );

# A second question does not inherit the first one's evidence.
my $second = $tira->question_add( project => $root, ref => $card->{ref}, text => 'And this?' );
is_deeply( $second->{attachments} // [], [], 'a different question starts with none' );

# The owner answers, and attaches while answering.
my $answered = $tira->question_answer(
    project => $root, id => $first->{id}, text => 'That one.',
    file => file_at( 'proof.pdf', 'PDF-proof' ) );
is( scalar @{ $answered->{answer}{attachments} }, 1, 'answering can carry its own evidence' );
is( $answered->{answer}{attachments}[0]{original_filename}, 'proof.pdf', 'kept by name' );

# The agent then sees all three against that question: its two and the owner's one.
my $scoped = $tira->attachment_list(
    project => $root, ref => $card->{ref}, meta_only => 1, questions => [ $first->{id} ] );
is( $scoped->{count}, 3,
    'the two it asked with and the one that came back are listed together' );
is_deeply(
    [ sort map { $_->{original_filename} } @{ $scoped->{attachments} } ],
    [ 'proof.pdf', 'screen.png', 'trace.log' ], 'all three by name' );

# Naming a question with nothing on it shows nothing, not everything.
is( $tira->attachment_list(
        project => $root, ref => $card->{ref}, meta_only => 1, questions => [ $second->{id} ] )->{count},
    0, 'naming a question with no evidence shows none of the other question\'s' );

# Naming none shows everything on the card, which is what makes a zero mean
# something.
$tira->attachment_add_content( project => $root, ref => $card->{ref},
    filename => 'oncard.txt', content => 'card level' );
is( $tira->attachment_list( project => $root, ref => $card->{ref}, count => 1 )->{count}, 4,
    'naming no question shows every file on the card' );

# Each says where it came from, so a list of four is navigable.
my $all = $tira->attachment_list( project => $root, ref => $card->{ref}, meta_only => 1 );
my %where = map { $_->{original_filename} => $_->{attached_to} } @{ $all->{attachments} };
is( $where{'screen.png'}, "question $first->{id}", 'evidence for the question says so' );
is( $where{'proof.pdf'}, "answer $first->{id}", 'and evidence with the answer says so' );
is( $where{'oncard.txt'}, 'card', 'and a card attachment is still a card attachment' );

# The same file twice is one reference, not two rows saying the same thing.
$tira->question_attach( project => $root, id => $first->{id}, file => file_at( 'screen.png', 'PNG-one' ) );
is( scalar @{ $tira->question_list( project => $root, ref => $card->{ref} )->{questions}[0]{attachments} },
    2, 'attaching the same file again does not duplicate it' );

# A wrong file can be taken off.
my $trimmed = $tira->question_attach(
    project => $root, id => $first->{id}, filename => 'trace.log', remove => 1 );
is( scalar @{ $trimmed->{attachments} }, 1, 'evidence can be removed' );
eval { $tira->question_attach( project => $root, id => $first->{id}, filename => 'nothing.txt', remove => 1 ) };
like( $@, qr/No attachment called/, 'and removing what is not there says so' );

# Nothing can be hung on an answer that does not exist.
eval { $tira->question_attach( project => $root, id => $second->{id},
        file => file_at( 'early.txt', 'too soon' ), to => 'answer' ) };
like( $@, qr/not been answered/, 'evidence cannot precede the answer it belongs to' );

# Fetching needs only the reference: no card, no question, no choosing.
my $wanted = $all->{attachments}[0];
my $fetched = $tira->attachment_get(
    project => $root, sha => $wanted->{sha}, extension => $wanted->{extension} );
ok( length $fetched->{content}, 'a file is fetched by its reference alone' );

# The command line.
my ( $status, $out ) = cli( 'question.attach', '--project', $root,
    '--id', $second->{id}, '--file', file_at( 'cli.txt', 'from the cli' ), '-o', 'json' );
is( $status, 0, 'the CLI attaches evidence' );
is( scalar @{ decode_json($out)->{attachments} }, 1, 'and reports it' );

( $status, $out ) = cli( 'attachment.list', '--project', $root, '--ref', $card->{ref},
    '--question', $second->{id}, '--meta-only', '-o', 'json' );
is( $status, 0, 'the CLI narrows to one question' );
is( decode_json($out)->{count}, 1, 'and shows only that question\'s' );

( $status, $out, my $err ) = cli( 'ticket.list', '--project', $root, '--question', 'Q-001', '-o', 'json' );
is( $status, 2, 'naming a question is refused where it means nothing' );

# The board uploads bytes rather than a path, so it has its own way in. It must
# reach the same engine method the command line does, or dropping a file on a
# question would quietly behave differently from attaching one.
{
    require MIME::Base64;
    my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
    my $dropped = decode_json(
        $providers{question_attach}->( {
            id => $second->{id}, filename => 'dropped.png',
            content_base64 => MIME::Base64::encode_base64('PNG-dropped'),
        } )
    );
    ok( $dropped->{ok}, 'the board can attach a dropped file' );
    is( scalar @{ $dropped->{question}{attachments} }, 2,
        'and it joins what that question already had' );
    is( $dropped->{question}{attachments}[1]{original_filename}, 'dropped.png',
        'keeping the name it was dropped under' );

    # Onto the answer once there is one, since that is who is attaching by then.
    $tira->question_answer( project => $root, id => $second->{id}, text => 'Answered now.' );
    my $onto_answer = decode_json(
        $providers{question_attach}->( {
            id => $second->{id}, to => 'answer', filename => 'reply.png',
            content_base64 => MIME::Base64::encode_base64('PNG-reply'),
        } )
    );
    is( scalar @{ $onto_answer->{question}{answer}{attachments} }, 1,
        'a file dropped after answering hangs on the answer' );

    for my $payload ( undef, [], { id => $second->{id} },
        { id => $second->{id}, filename => 'x.png' } ) {
        my $error = eval { $providers{question_attach}->($payload); 1 } ? '' : $@;
        like( $error, qr/question|filename|content/i, 'a malformed upload is refused' );
    }
    my $empty = eval {
        $providers{question_attach}->( {
            id => $second->{id}, filename => 'nothing.png', content_base64 => '' } );
        1;
    } ? '' : $@;
    like( $empty, qr/empty/i, 'and an upload with no bytes in it' );
}

done_testing;

__END__

=head1 NAME

71-question-attachments.t - evidence on a question and on its answer

=head1 DESCRIPTION

An agent asks with evidence and the owner answers with evidence, and
both belong to the question, because somebody reading it wants
everything bearing on it rather than a tidy taxonomy. Proves a question
carries its own files, that another question inherits none of them,
that answering can attach in the same action, that naming a question
narrows the list to it while naming none shows every file on the card,
that each entry says where it came from, and that a file is fetched by
its reference alone with no card or question to name.

=cut
