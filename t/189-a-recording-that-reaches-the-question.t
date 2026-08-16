#!/usr/bin/env perl
# A recording handed to the ask command reaches the question.
#
# Found by using it. Asking a question with --voice produced a question whose
# own reminder read "missing: voice | fix: tira.question.update --id Q-034
# --voice FILE" - the command was told about the recording, said nothing, and
# then complained that nobody had given it one.
#
# Everything around the failure believes it works. The dispatcher refuses
# --voice on any other command with "A voice note belongs to the question.ask,
# question.update and question.voice commands" (lib/Tira/CLI.pm:1598), so the
# option is validated as belonging to ask. Tira::question_add ends by attaching
# it, after the question exists so that a bad recording fails the voice rather
# than the question. The manual documents it. One line passed it through for
# update only:
#
#     $question{voice} = $option->{voice} if defined $option->{voice}
#       && $action eq 'update';
#
# A setting accepted, validated, and thrown away - the shape this board keeps
# finding, and the reason it is worth a test rather than a one-word edit: the
# option can stop being passed again tomorrow and nothing else would notice.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'board' );

$tira->project_new(
    name => 'Asking', dir => $root, members => [ 'claude', 'michael' ],
    columns => ['backlog, done'],
    sow_prefix => 'AKS', epic_prefix => 'AKE', ticket_prefix => 'AKT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Something to ask about' )->{ref};

my $recording = File::Spec->catfile( $tmp, 'question.ogg' );
open my $sound, '>:raw', $recording or die $!;
print {$sound} "OggS\0\2\0\0\0\0\0\0\0\0";
close $sound;

sub ask {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => 'question.ask', tira => $tira, argv => \@argv );
    };
    return ( $status, $out, $err );
}

my ( $status, $out, $err ) = ask(
    '--ref', $card, '--author', 'claude', '--text', 'Which way round is it?',
    '--voice', $recording, '-o', 'json' );

is( $status, 0, 'the question is asked' ) or diag($err);

my $asked = Tira::json_decode($out);
ok( defined $asked->{voice} && $asked->{voice} ne '',
    'and the recording handed to it is on the question' );

# --- and the card does not then ask for what it was given ---------------------------
#
# The symptom as it was actually met: the reminder telling its own author to
# supply the thing they had just supplied.

{
    # question_list answers a record about the card - the reference, its title,
    # the questions and an instruction for whoever reads it - rather than a bare
    # list. Treating it as an arrayref died here, which is the right way round:
    # the test found the shape rather than assuming it.
    my ($question) = @{ $tira->question_list( project => $root, ref => $card )->{questions} };
    ok( defined $question->{voice}, 'the stored question carries it too' );
}

# --- a question asked without one is unchanged -----------------------------------------

{
    my ( undef, $plain ) = ask(
        '--ref', $card, '--author', 'claude', '--text', 'And this one has no recording',
        '-o', 'json' );
    my $quiet = Tira::json_decode($plain);
    ok( !defined $quiet->{voice} || $quiet->{voice} eq '',
        'a question asked without a recording still has none' );
}

# --- and update, which always worked, still does -----------------------------------------

{
    my ($first) = @{ $tira->question_list( project => $root, ref => $card )->{questions} };
    my ( $ok, $updated ) = do {
        my ( $o, $e ) = ( '', '' );
        open my $so, '>', \$o or die $!;
        open my $se, '>', \$e or die $!;
        my $st = do {
            local *STDOUT = $so;
            local *STDERR = $se;
            do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'question.update', tira => $tira,
                argv => [ '--id', $first->{id}, '--voice', $recording,
                    '-o', 'json' ] ) };
        };
        ( $st, $o );
    };
    is( $ok, 0, 'question.update still takes a recording' );
}

done_testing;

__END__

=head1 NAME

189-a-recording-that-reaches-the-question.t - --voice on ask is not thrown away

=head1 DESCRIPTION

C<tira.question.ask --voice FILE> accepted the recording, refused it on every
command it does not belong to, and then dropped it: one line in the dispatcher
passed it through for C<update> alone. The engine had always attached it, and
the manual had always documented it, so the only thing that disagreed was the
code between them.

=cut
