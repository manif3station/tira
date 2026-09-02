#!/usr/bin/env perl
# A card body typed into an option the command does not read.
#
# TKT-849, reported by Michael on 2026-09-02: "tira.ticket.create ACCEPTS
# --text and silently discards it, so a card is created with an empty body
# while the command reports success." He only noticed because he read the card
# back.
#
# REPRODUCED on 5.35 in a container before this file was written:
#
#     skills/ticket/cli/create --title 'probe card' --text 'THIS BODY SHOULD NOT VANISH'
#       -> exit 0, prints the whole new record
#     skills/ticket/cli/show --ref PRT-001 -o json
#       -> description = None, problem_or_feature = None
#
# WHY IT IS NOT AN UNKNOWN OPTION, which is the thing that makes it dangerous:
# --text is real and IS read, by eleven engine subs. The parser is shared, so
# ticket.create takes it, has nothing to do with it, and drops it. A caller
# reaching for "how do I give this card a body" tries the plausible name, gets
# no error, and gets an empty card.
#
# THE HALF THAT CAN BREAK THINGS is the reader list, and it was counted from the
# ENGINE rather than from the CLI - by walking every .pm under lib/ except
# lib/Tira/CLI and recording which sub each $args{text} read sits in. record.list
# is the reader a CLI-only count loses, and it is what ticket.list, epic.list and
# sow.list all reach, where --text is a working filter. t/237 records that the
# --field refusal was nearly written from exactly that mistake and would have
# broken two working commands; this one has a wider blast radius, so the
# surviving-readers section below is not decoration.
#
# WRITTEN RED. The refusal does not exist yet, so today ticket.create --text
# succeeds and writes nothing - which is the fault, asserted directly rather
# than inferred.
#
# WHAT IS DELIBERATELY NOT ASSERTED: that --text ends up in the description. He
# offered that as his option 2 ("Or honour it, mapping --text to description on
# create") and said either was fine. Refusing is what all five existing entries
# in this table do, and it is reversible; quietly writing a body into a field
# the caller did not name is not.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-02T21:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Bodied', dir => $root,

    # michael is a member because dev.found.bug_or_improvement raises its card
    # as the owner - an agent in another project is not a member here, so the
    # origin becomes a label and the owner becomes the reporter.
    members    => [ 'claude', 'michael' ],
    columns    => ['backlog, implement, done'],
    sow_prefix => 'BDS', epic_prefix => 'BDE', ticket_prefix => 'BDT',
);

sub run {
    my ( $command, @argv ) = @_;

    # Mirror the installed dispatcher: a board command carries its type
    # separately, so ticket.create reaches the engine as record.create. This is
    # the detail that decides the refusal - ticket.create and ticket.list arrive
    # as record.create and record.list, so the guard has to tell two commands
    # apart that share a prefix, and one of them genuinely reads --text.
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            $ENV{TIRA_AUTHOR} = 'claude';
            Tira::CLI->run( command => $command, type => $type, tira => $tira,
                argv => [@argv] );
        };
    };
    return ( $status, $out, $err );
}

sub card_count {
    return scalar @{ $tira->record_list( project => $root, type => 'ticket' ) };
}

# --- what he typed, and what the board kept ----------------------------------

my $before = card_count();

my ( $status, undef, $err ) = run( 'ticket.create',
    '--title', 'A card somebody tried to give a body',
    '--text',  'THIS BODY SHOULD NOT VANISH' );

isnt( $status, 0, 'ticket.create refuses --text rather than dropping it' );
like( $err, qr/--problem/,
    'and names the option that does carry a body, the way every other refusal in this guard does' );

# The half he actually cares about. A refusal that still left the card behind
# would trade a silent empty card for a loud one, and the unknown-option path
# already gets this right - it refuses BEFORE anything is written.
is( card_count(), $before,
    'and no card is left behind, so the refusal happens before creation' );

# --- the same body through the option that does carry it ---------------------

my ($ok) = run( 'ticket.create',
    '--title',   'A card given a body the right way',
    '--problem', 'THIS BODY SHOULD NOT VANISH' );
is( $ok, 0, 'the option the refusal names actually works' );

my ($written) = grep { ( $_->{title} // '' ) =~ /the right way/ }
  @{ $tira->record_list( project => $root, type => 'ticket' ) };
ok( $written, 'and the card it names really was created' );
is( $written->{problem_or_feature}, 'THIS BODY SHOULD NOT VANISH',
    'carrying the body, which is the thing that went missing' );

# --- the readers that must not be caught -------------------------------------
#
# Counted from the engine: comment_add, comment_update, question_add,
# question_answer, question_update, record_list, search, tasklist_add,
# tasklist_slice, tasklist_unshift, tasklist_update. Refusing any of these
# would trade a silent failure for a broken command, which is the trade t/237
# was nearly written into.

my $card = $written->{ref};

{
    my ( $said, $out ) = run( 'comment.add', '--ref', $card, '--text', 'a real comment' );
    is( $said, 0, 'comment.add still reads --text' );

    # non-empty is the whole claim: an empty answer would satisfy any
    # assertion about what the comment does or does not contain.
    like( $out, qr/\S/, 'and answers with something' );
    like( $out, qr/a real comment/, 'having actually recorded the body' );
}

{
    # record.list is the one a CLI-only count loses, and it arrives under the
    # same record.* prefix as the command being refused.
    my ( $said, $out ) = run( 'ticket.list', '--text', 'the right way' );
    is( $said, 0, 'ticket.list still reads --text as a filter' );

    # non-empty is the whole claim: this is the precondition for the match
    # below, which would pass happily against a command that printed nothing.
    like( $out, qr/\S/, 'and answers with something' );
    like( $out, qr/\Q$card\E/, 'finding the card whose body matches' );
}

{
    my ( $said, $out ) = run( 'tasklist.add', '--text', 'a real task' );
    is( $said, 0, 'tasklist.add still reads --text' );

    # non-empty is the whole claim: the match below is about what the answer
    # contains, and an empty answer contains nothing to be wrong about.
    like( $out, qr/\S/, 'and answers with something' );
    like( $out, qr/a real task/, 'having actually stored the text' );
}

{
    my ( $said, $out ) = run( 'search', '--text', 'the right way' );
    is( $said, 0, 'search still reads --text as the thing being searched for' );

    # non-empty is the whole claim: a search that answered nothing would
    # satisfy any assertion about what it did not find.
    like( $out, qr/\S/, 'and answers with something' );
}

# The reader an engine-only count loses, and the one that actually broke.
#
# dev.found.bug_or_improvement reads --text in the CLI layer and hands it to
# create_record as the description, so there is no $args{text} read in the
# engine to find. The first version of this guard refused it and t/132 failed -
# the command whose whole job is letting an agent in another project report a
# fault in Tira, which is how this very card could have been filed.
#
# Asserted here as well as in t/132 because that file is about the reporting
# path and this one is about the guard: a later edit to the reader list should
# fail on the card that owns the list.
{
    # This one finds the board itself rather than being handed it, because the
    # caller is in another project and must not learn where this board lives.
    # t/132 stubs the same resolver for the same reason.
    no warnings 'redefine';
    local *Tira::CLI::_tira_home = sub { $root };

    my ( $said, $out ) = run( 'dev.found.bug_or_improvement',
        '--from', 'telegram-codex', '--title', 'A fault found elsewhere',
        '--text', 'what was actually found', '-o', 'json' );
    is( $said, 0, 'an out-of-project bug report still reads --text' );

    # non-empty is the whole claim: the match below asks what the answer says,
    # and an empty answer says nothing to be wrong about.
    like( $out, qr/\S/, 'and answers with something' );
    like( $out, qr/\ATKT-|"ref"/, 'naming the card it raised' );
}

# question.ask, question.answer and question.update read --text too. They are
# asserted differently on purpose: those commands have their own requirements
# (a question needs a voice note and a reason on this board), so a plain call
# can fail for reasons that have nothing to do with this guard. What must be
# true is that THIS refusal is not what stops them.
for my $verb (qw(question.ask question.answer question.update)) {
    my ( undef, $out, $why ) = run( $verb, '--ref', $card, '--text', 'a real question' );
    my $answer = $out . $why;

    # The denial below is about what this answer does NOT say, so a command
    # that printed nothing would satisfy it while proving nothing. That is the
    # fault t/147 catches, and it caught this block in its first form.
    #
    # Measured rather than hoped: question.ask succeeds and prints the question
    # it created, while question.answer and question.update refuse for wanting
    # --id. All three say something.
    #
    # non-empty is the whole claim: it establishes the subject of the unlike.
    like( $answer, qr/\S/, "$verb answers something at all" );
    unlike( $answer, qr/does not act on --text/,
        "$verb is not caught by the --text refusal, whatever else it needs" );
}

# --- and the fault itself, proved by taking the refusal away -----------------
#
# Without the guard the command reports success and writes nothing, which is
# exactly what he saw. This is the assertion that says the refusal is load
# bearing rather than decorative.

{
    no warnings 'redefine';
    local *Tira::CLI::_refuse_unread_options = sub { return };

    my $was = card_count();
    my ($allowed) = run( 'ticket.create',
        '--title', 'The same attempt without the refusal',
        '--text',  'THIS BODY SHOULD NOT VANISH' );

    is( $allowed, 0, 'without the guard the command reports success' );
    is( card_count(), $was + 1, 'and does create the card' );

    my ($empty) = grep { ( $_->{title} // '' ) =~ /without the refusal/ }
      @{ $tira->record_list( project => $root, type => 'ticket' ) };
    ok( $empty, 'which is right there to be read back' );
    ok( !length( $empty->{problem_or_feature} // '' ),
        'with no body at all - the success message was the only thing that arrived' );
    ok( !length( $empty->{description} // '' ),
        'and nothing in the description either, so it went nowhere rather than somewhere else' );
}

done_testing();

__END__

=head1 NAME

497-a-body-that-never-arrived.t - ticket.create must refuse --text, not eat it

=head1 WHY

TKT-849. C<tira.ticket.create --text BODY> exits 0, prints the new card back,
and keeps none of the body. Michael reported it after a card he filed came back
empty, and it reproduces on 5.35.

=head1 THE READER LIST IS THE RISKY HALF

C<--text> is read by eleven engine subs, so the refusal has to name them all or
it breaks working commands. They were counted by walking the engine rather than
the CLI, because C<record_list> - reached by C<ticket.list>, C<epic.list> and
C<sow.list>, where C<--text> is a working filter - is invisible from the CLI
side. F<t/237> records the same near-miss for C<--field>.

C<record.create> and C<record.list> arrive under the same prefix, so this is a
guard that has to separate two commands that look alike and behave oppositely.

=head1 WHAT IS NOT ASSERTED

That C<--text> is honoured and mapped to the description. He offered that and
said either fix was fine; refusing matches the five entries already in this
table and is reversible, where silently writing a body into a field the caller
did not name is not.

=cut
