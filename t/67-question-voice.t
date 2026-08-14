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
my $tira = Tira->new( clock => sub { '2026-08-09T09:00:00Z' } );

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

sub recording {
    my ( $name, $bytes ) = @_;
    my $path = File::Spec->catfile( $tmp, $name );
    open my $fh, '>:raw', $path or die $!;
    print {$fh} $bytes;
    close $fh;
    return $path;
}

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Voice', dir => $root, columns => ['Backlog, Doing'],
    sow_prefix => 'VCS', epic_prefix => 'VCE', ticket_prefix => 'VCT' );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Needs asking' );

my $note = recording( 'question.ogg', 'OggS-pretend-audio' );

# Asked with a recording in one command, which is how an agent that has just
# written the question and its choices would do it.
my $asked = $tira->question_add(
    project => $root, ref => $card->{ref}, text => 'Which store?',
    reason => 'Two are configured.', options => [ 'Staging', 'Live' ],
    voice => $note,
);
ok( $asked->{voice}, 'a question can be asked with its recording attached' );
is( $asked->{voice}{extension}, 'ogg', 'which keeps its kind' );
is( $asked->{voice}{original_filename}, 'question.ogg', 'and its name' );
is( $asked->{text}, 'Which store?', 'and the question is unchanged by it' );
is_deeply( $asked->{options}, [ 'Staging', 'Live' ], 'as are its choices' );

# Stored where every attachment is stored, so it is deduplicated and served by
# the route that already exists rather than a second one.
my $stored = File::Spec->catfile(
    $root, '.tira', 'attachments', "$asked->{voice}{sha}.ogg" );
ok( -f $stored, 'the recording is kept in the ordinary attachment store' );
is( -s $stored, length 'OggS-pretend-audio', 'byte for byte' );

# The same recording twice is one file.
my $second = $tira->question_add( project => $root, ref => $card->{ref}, text => 'Again?' );
$tira->question_voice( project => $root, id => $second->{id}, file => $note );
my @files = glob File::Spec->catfile( $root, '.tira', 'attachments', '*.ogg' );
is( scalar @files, 1, 'the same recording on two questions is stored once' );

# Replaced, because a question can be taken apart afterwards and its old
# recording then describes something that no longer exists.
my $better = recording( 'better.mp3', 'ID3-pretend-audio' );
my $replaced = $tira->question_voice( project => $root, id => $asked->{id}, file => $better );
is( $replaced->{voice}{extension}, 'mp3', 'a recording can be replaced' );
isnt( $replaced->{voice}{sha}, $asked->{voice}{sha}, 'with different content' );
ok( -f $stored, 'and the old bytes stay, because another question still points at them' );

# Removed, because a wrong recording should not be permanent.
my $silent = $tira->question_voice( project => $root, id => $asked->{id}, remove => 1 );
ok( !defined $silent->{voice}, 'a recording can be removed' );
eval { $tira->question_voice( project => $root, id => $asked->{id}, remove => 1 ) };
like( $@, qr/no voice note/i, 'and removing one that is not there says so' );

# What is refused.
for my $case (
    [ { id => $asked->{id}, file => recording( 'notes.txt', 'words' ) }, qr/must be audio/, 'a file that is not audio' ],
    [ { id => $asked->{id}, file => recording( 'empty.ogg', '' ) }, qr/is empty/, 'an empty recording' ],
    [ { id => $asked->{id} }, qr/needs a file/, 'no file at all' ],
    [ { id => 'Q-404', file => $note }, qr/Q-404/, 'a question that does not exist' ],
) {
    my ( $args, $error, $label ) = @{$case};
    eval { $tira->question_voice( project => $root, %{$args} ) };
    like( $@, $error, "$label is refused" );
}
# non-empty is the whole claim: each case above pins its own message, and
# this says the last of them was not silent.
like( $@, qr/\S/, 'every refusal says something' );

# A question with a bad recording is still asked: losing the question because
# the audio was wrong would be the wrong trade.
my $partial = eval {
    $tira->question_add( project => $root, ref => $card->{ref},
        text => 'Asked despite a bad recording', voice => File::Spec->catfile( $tmp, 'notes.txt' ) );
};
like( $@, qr/must be audio/, 'a bad recording fails the command' );
ok( scalar( grep { $_->{text} eq 'Asked despite a bad recording' }
        @{ $tira->question_list( project => $root, ref => $card->{ref} )->{questions} } ),
    'but the question itself was still asked, rather than lost with it' );

# The CLI.
my ( $status, $out ) = cli( 'question.voice', '--project', $root,
    '--id', $second->{id}, '--voice', $better, '-o', 'json' );
is( $status, 0, 'the CLI attaches a recording' );
is( decode_json($out)->{voice}{extension}, 'mp3', 'and reports it' );

( $status, $out ) = cli( 'question.voice', '--project', $root,
    '--id', $second->{id}, '--remove', '-o', 'json' );
is( $status, 0, 'and removes one' );

( $status, $out, my $err ) = cli( 'question.voice', '--project', $root,
    '--id', $second->{id}, '--voice', $better, '--remove', '-o', 'json' );
is( $status, 2, 'asking to both attach and remove exits 2' );
like( $err, qr/only one/i, 'and says why' );

( $status, $out, $err ) = cli( 'ticket.list', '--project', $root, '--voice', $note, '-o', 'json' );
is( $status, 2, 'a recording is refused on commands it does not belong to' );

# The board plays it without a second player or a second route.
my $html = $tira->format_output(
    $tira->dashboard( project => $root, type => 'ticket', summary => 1 ),
    output => 'table', project => $root, live => 1 );
like( $html, qr/card-question__play/, 'the question block offers a play control' );
like( $html, qr/attachmentUrl\(question\.voice\.sha,question\.voice\.extension\)/,
    'served by the route that already serves attachments' );
like( $html, qr/if\(question\.voice\)\{/, 'and a question without a recording shows no control' );

# An agent will not use a feature nobody tells it about. These lines
# are read by an LLM and Tira exists to spend fewer tokens than Jira, so they
# are terse and mechanical rather than prose, and the fixes go on one line.
{
    my $bare = $tira->question_add(
        project => $root, ref => $card->{ref}, text => 'Nothing but a question' );
    my $owed = $bare->{reminder};
    like( $owed, qr/\Amissing: reason,options,voice \| fix: /,
        'all three gaps are named at once, in one machine-readable line' );
    like( $owed, qr/\Qfix: tira.question.update --id $bare->{id} --reason TEXT --option TEXT --option TEXT --voice FILE\E/,
        'and one command settles all three, because needing two would be the command surface telling on itself' );
    unlike( $owed, qr/;/, 'so there is no second command to run' );
    unlike( $owed, qr/\n/, 'the whole reminder is a single line' );
    ok( length($owed) < 200, 'and short, because every character is somebody\'s tokens' );

    # Each gap is settled on its own, and settling one does not silence the rest.
    my $with_reason = $tira->question_update(
        project => $root, id => $bare->{id}, reason => 'Because it matters.' );
    like( $with_reason->{reminder}, qr/\Amissing: options,voice/,
        'giving a reason settles that one and leaves the others' );
    unlike( $with_reason->{reminder}, qr/--reason TEXT/,
        'and stops offering to fix what is no longer missing' );

    my $with_options = $tira->question_update(
        project => $root, id => $bare->{id}, options => [ 'One', 'Two' ] );
    like( $with_options->{reminder}, qr/\Amissing: voice \|/, 'and the choices settle theirs' );

    # Everything at once, in the single command the reminder offered.
    my $swept = $tira->question_update(
        project => $root, id => $bare->{id}, reason => 'Fresh reason',
        options => [ 'X', 'Y' ], voice => $note );
    is( $swept->{reminder}, undef, 'one command can settle a question that owed all three' );
    is( $swept->{reason}, 'Fresh reason', 'setting the reason' );
    is_deeply( $swept->{options}, [ 'X', 'Y' ], 'the choices' );
    ok( $swept->{voice}, 'and the recording together' );

    my $complete = $tira->question_voice(
        project => $root, id => $bare->{id}, file => $note );
    is( $complete->{reminder}, undef, 'a question that owes nothing carries no reminder at all' );
}

# Changing what a question says makes its recording describe an older wording.
{
    my $recorded = $tira->question_add(
        project => $root, ref => $card->{ref}, text => 'Complete from the start',
        reason => 'A reason.', options => [ 'A', 'B' ], voice => $note );
    is( $recorded->{reminder}, undef, 'a question asked complete owes nothing' );

    my $reworded = $tira->question_update(
        project => $root, id => $recorded->{id}, text => 'Reworded entirely' );
    like( $reworded->{reminder}, qr/\Amissing: voice\(stale\) \|/,
        'rewording marks the recording stale rather than merely absent' );
    like( $reworded->{reminder}, qr/\Qtira.question.update --id $recorded->{id} --voice FILE\E/,
        'with the one command that replaces it' );

    my $fixed = $tira->question_voice(
        project => $root, id => $recorded->{id}, file => recording( 'fresh.ogg', 'OggS-fresh' ) );
    is( $fixed->{reminder}, undef, 'and replacing it settles the matter' );

    # Changing only the choices counts too: the recording reads them out.
    my $rechoiced = $tira->question_update(
        project => $root, id => $recorded->{id}, options => [ 'New', 'Choices' ] );
    like( $rechoiced->{reminder}, qr/voice\(stale\)/,
        'changing only the choices makes the recording stale as well' );

    $tira->question_discard( project => $root, id => $recorded->{id} );
    my ($gone) = grep { $_->{id} eq $recorded->{id} }
      @{ $tira->question_list( project => $root, ref => $card->{ref} )->{questions} };
    is( $gone->{reminder}, undef, 'a question set aside is not nagged about' );
}

# It reaches the agent wherever a question comes back, not only in the list.
{
    my $fresh = $tira->question_add(
        project => $root, ref => $card->{ref}, text => 'Reminders everywhere' );
    my ($listed) = grep { $_->{id} eq $fresh->{id} }
      @{ $tira->question_list( project => $root, ref => $card->{ref} )->{questions} };
    like( $listed->{reminder}, qr/missing:/, 'the list carries it' );
    like( $tira->question_answer( project => $root, id => $fresh->{id}, text => 'Answered' )->{reminder},
        qr/missing:/, 'and so does answering' );
    like( $tira->question_mark( project => $root, id => $fresh->{id}, mark => 'ok' )->{reminder},
        qr/missing:/, 'and marking' );
}

done_testing;

__END__

=head1 NAME

67-question-voice.t - a voice note on a question

=head1 DESCRIPTION

The agent records the audio and hands over a path; Tira stores it and
serves it. Tira never speaks the text itself, because it runs no
external process, and that rule is worth more than the convenience of
generating audio. Proves the recording is kept in the ordinary
content-addressed attachment store, so the same recording on two
questions is one file and the route that already serves attachments
serves this; that it can be replaced when a question is taken apart and
removed when it is simply wrong; that anything which is not audio is
refused; and that a bad recording fails the recording rather than
losing the question.

=cut
