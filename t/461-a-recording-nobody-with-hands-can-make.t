#!/usr/bin/env perl
# TKT-787. tira.question.ask's own reminder said "missing: voice | fix:
# tira.question.update --id Q-NNN --voice FILE" whether the caller was a
# human with a phone or an agent with none - an agent asking a question
# had no sanctioned way inside Tira to produce that recording at all, and
# ended up reaching into a sibling project's own TTS tooling as a one-off
# workaround, exactly the cross-project coupling this workspace's own
# governance warns against.
#
# Q-101/Q-102 (answered by the owner 2026-08-31): --caller-kind agent|human
# on question.ask, defaulting to human so every existing and human-filed
# question keeps today's reminder unchanged. The voice half of the
# reminder is skipped for a question whose caller_kind is 'agent' - the
# reason/options half still fires for everyone, since that costs nothing
# an agent cannot produce.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use Cpanel::JSON::XS qw(decode_json);

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub { '2026-08-31T21:00:00+0100' } );
$tira->create_project( name => 'Caller kind', dir => $root );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Something to ask about' );

# Default (no --caller-kind at all): unchanged from before this ticket -
# every question ever asked reads as human, and the voice reminder fires.
my $human_default = $tira->question_add(
    project => $root, ref => $card->{ref}, author => 'ada', text => 'Which store?' );
is( $human_default->{caller_kind}, 'human', 'a question with no caller-kind given defaults to human' );
like( $human_default->{reminder}, qr/\bvoice\b/,
    'and the voice reminder still fires for it, unchanged' );

# Explicit human: identical behavior, named rather than assumed.
my $human_explicit = $tira->question_add(
    project => $root, ref => $card->{ref}, author => 'ada', text => 'Which bucket?',
    caller_kind => 'human' );
like( $human_explicit->{reminder}, qr/\bvoice\b/, 'an explicit human caller still gets the voice reminder' );

# The actual fix: an agent-filed question is not nudged toward a recording
# it has no way to produce.
my $agent = $tira->question_add(
    project => $root, ref => $card->{ref}, author => 'claude', text => 'Which store should this write to?',
    caller_kind => 'agent' );
is( $agent->{caller_kind}, 'agent', 'the caller kind is stored on the question' );
unlike( $agent->{reminder} // '', qr/\bvoice\b/,
    'and an agent-filed question is not reminded to attach a recording it cannot make' );
like( $agent->{reminder}, qr/reason|options/,
    'the rest of the reminder (reason/options) still applies to an agent the same as anyone else' );

# Case is not the contract - Agent, AGENT, agent all read the same way.
my $agent_mixed_case = $tira->question_add(
    project => $root, ref => $card->{ref}, author => 'claude', text => 'Mixed case caller kind?',
    caller_kind => 'AgEnT' );
is( $agent_mixed_case->{caller_kind}, 'agent', 'caller_kind is normalized to lowercase on write' );

# A misspelling is refused by name, the same discipline TKT-668 gave status.
eval {
    $tira->question_add(
        project => $root, ref => $card->{ref}, author => 'claude', text => 'Bad kind',
        caller_kind => 'robot' );
};
like( $@, qr/Unknown caller kind 'robot' - the values that work are agent and human/,
    'an unrecognised caller kind is refused, naming the value given and the ones that work' );

# --caller-kind belongs to question.ask alone, the same restriction --voice
# already has on question.update/question.voice.
use Tira::CLI;
sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => $command, argv => \@argv, tira => $tira );
    return ( $status, $out, $err );
}
my ( $status, undef, $err ) = cli(
    'question.update', '--ref', $card->{ref}, '--id', $agent->{id}, '--caller-kind', 'human' );
isnt( $status, 0, '--caller-kind is refused on question.update' );
like( $err, qr/--caller-kind is available on the question\.ask command/,
    'naming the one command it belongs to' );

# The same refusal for two more question.* commands that route through a
# different dispatch path entirely (not question_verbs) - a Codex review
# caught this card's own first draft leaving --caller-kind silently
# accepted and ignored on both, because the refusal lived only inside
# question_verbs, which question.voice/question.attach never reach.
for my $other_command (qw(question.voice question.attach)) {
    my ( $other_status, undef, $other_err ) = cli(
        $other_command, '--id', $agent->{id}, '--caller-kind', 'agent' );
    isnt( $other_status, 0, "--caller-kind is also refused on $other_command" );
    like( $other_err, qr/--caller-kind is available on the question\.ask command/,
        "and $other_command names the one command it belongs to, same as question.update" );
}

# The real CLI path for the fix itself, not just the direct library call
# every other assertion above uses - proves the option spec and
# question_verbs forwarding are actually wired together, not just that
# question_add's own validation works when called directly.
my ( $ask_status, $ask_out ) = cli(
    'question.ask', '--ref', $card->{ref}, '--text', 'Asked via the real CLI path',
    '--caller-kind', 'agent', '-o', 'json' );
is( $ask_status, 0, 'question.ask --caller-kind agent succeeds via the real CLI path' );
my $ask_decoded = eval { decode_json($ask_out) };
is( $ask_decoded->{caller_kind}, 'agent',
    'and the CLI-created question carries caller_kind through option spec and question_verbs, not just the library call' );

# A question created before this fix carries no caller_kind field at all -
# it must still read as human, not die on an undef comparison.
my $legacy_record = $tira->record_show( project => $root, ref => $card->{ref} );
delete $_->{caller_kind} for @{ $legacy_record->{questions} };
$tira->_replace_record( project => $root, type => 'ticket', ref => $card->{ref}, record => $legacy_record );
my $reread = $tira->question_list( project => $root, ref => $card->{ref} );
my ($reread_human) = grep { $_->{id} eq $human_default->{id} } @{ $reread->{questions} };
like( $reread_human->{reminder}, qr/\bvoice\b/,
    'a legacy question with no caller_kind field at all still reads as human' );

done_testing;

__END__

=head1 NAME

t/461-a-recording-nobody-with-hands-can-make.t - the voice reminder no
longer nudges an agent toward a recording it cannot produce

=head1 DESCRIPTION

C<tira.question.ask>'s reminder told an agent asking a question to attach
a voice recording, the same as a human caller with a phone - Tira itself
has no synthesis capability, so satisfying the reminder honestly meant
reaching into a sibling project's own TTS tooling, exactly the
cross-project coupling this workspace's governance warns against.

Fixed (Q-101/Q-102, owner 2026-08-31): C<--caller-kind agent|human> on
C<question.ask>, defaulting to C<human> so every existing and
human-filed question keeps its reminder unchanged. C<_question_reminder>
skips the voice half of its check for a question whose stored
C<caller_kind> is C<agent> - the reason/options half still applies to
everyone. TKT-787.

=cut
