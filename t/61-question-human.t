#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tick = '2026-08-09T09:00:00Z';
my $tira = Tira->new( clock => sub {$tick} );

# Every human render must be silent: a warning on stderr of an ordinary read
# teaches people to ignore this tool's warnings, which is the real cost.
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };

sub human {
    my ($payload) = @_;
    return $tira->format_output( $payload, output => 'human' );
}

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Human', dir => $root, members => ['ada'], columns => ['Backlog, Doing'],
    sow_prefix => 'HMS', epic_prefix => 'HME', ticket_prefix => 'HMT' );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Importer work' );
my $bare = $tira->create_record( project => $root, type => 'ticket', title => 'Nothing asked' );

# A card with no description used to warn on every single human read.
my $shown = human( $tira->record_show( project => $root, ref => $card->{ref} ) );
like( $shown, qr/# \Q$card->{ref}\E: Importer work/, 'a record still renders as it did' );
like( $shown, qr/_No description\._/, 'and says so when it has no description' );
is_deeply( \@warnings, [], 'without warning about the description it does not have' );

# The damaging one: a question list carries a ref, so it was drawn as a card.
my $question = $tira->question_add( project => $root, ref => $card->{ref},
    text => 'Which credentials should this use?', author => 'ada' );
@warnings = ();
my $listed = human( $tira->question_list( project => $root, ref => $card->{ref} ) );
is_deeply( \@warnings, [], 'listing questions warns about nothing' );
like( $listed, qr/# Questions on \Q$card->{ref}\E: Importer work/,
    'the heading names the card the way ticket.show does, title and all' );
unlike( $listed, qr/- Type:/, 'and it is not drawn as a card, which is what it was doing' );
like( $listed, qr/\Q$question->{id}\E/, 'the question is named' );
like( $listed, qr/Which credentials should this use\?/, 'the question is shown' );
like( $listed, qr/waiting on the owner/, 'and says who it is waiting on' );
like( $listed, qr/tira\.question\.mark/, 'the instruction line survives' );

# The answer belongs underneath it.
$tick = '2026-08-09T11:00:00Z';
$tira->question_answer( project => $root, id => $question->{id},
    text => "Use the read-only account.\nNot the admin one." );
@warnings = ();
$listed = human( $tira->question_list( project => $root, ref => $card->{ref} ) );
is_deeply( \@warnings, [], 'an answered question warns about nothing either' );
like( $listed, qr/> Use the read-only account\./, 'the answer is quoted under its question' );
like( $listed, qr/> Not the admin one\./, 'including every line of it' );
like( $listed, qr/answered 2026-08-09T11:00:00Z/, 'with when it was answered' );
like( $listed, qr/read 2026-08-09/, 'and that listing it has now marked it read' );
like( $listed, qr/not yet marked/, 'and that nobody has said whether it settles anything' );

$tira->question_mark( project => $root, id => $question->{id}, mark => 'ok' );
like( human( $tira->question_list( project => $root, ref => $card->{ref} ) ), qr/marked ok/,
    'once marked, it says so' );

# A card nobody asked about should say that, not print an empty card.
@warnings = ();
my $empty = human( $tira->question_list( project => $root, ref => $bare->{ref} ) );
like( $empty, qr/# Questions on \Q$bare->{ref}\E: Nothing asked/,
    'a card with no questions still names itself, with its title' );
like( $empty, qr/No questions have been asked/, 'and says there are none' );
unlike( $empty, qr/- Type:|- Assignee:/, 'rather than printing a blank card' );
is_deeply( \@warnings, [], 'and warns about nothing' );

# Set aside is visible too, since it still happened.
my $dropped = $tira->question_add( project => $root, ref => $bare->{ref}, text => 'Never mind' );
$tira->question_discard( project => $root, id => $dropped->{id} );
@warnings = ();
my $aside = human( $tira->question_list( project => $root, ref => $bare->{ref} ) );
like( $aside, qr/discarded/, 'a discarded question shows its status' );
like( $aside, qr/Set aside/, 'and when it was set aside' );
is_deeply( \@warnings, [], 'quietly' );

# A question worth answering says why it is being asked and what the agent can
# see, so the owner is not composing an answer from nothing.
@warnings = ();
my $rich = $tira->question_add(
    project => $root, ref => $bare->{ref},
    text => 'Which store should the importer write to?',
    reason => 'Both are configured and the runbook names neither.',
    options => [ 'The staging bucket', 'The live bucket', 'Neither, block until told' ],
);
is( $rich->{reason}, 'Both are configured and the runbook names neither.', 'a question keeps its reason' );
is_deeply( $rich->{options},
    [ 'The staging bucket', 'The live bucket', 'Neither, block until told' ],
    'and the options the agent could see' );
my $shown_rich = human( $tira->question_list( project => $root, ref => $bare->{ref} ) );
like( $shown_rich, qr/_Why:_ Both are configured/, 'the reason renders under the question' );
like( $shown_rich, qr/1\. The staging bucket/, 'the options render as a numbered list' );
like( $shown_rich, qr/3\. Neither, block until told/, 'all of them' );
is_deeply( \@warnings, [], 'and none of it warns' );

# Both stay optional: a bare question is still a question.
my $bare_q = $tira->question_add( project => $root, ref => $bare->{ref}, text => 'Plain one?' );
ok( !defined $bare_q->{reason}, 'a question without a reason has none' );
is_deeply( $bare_q->{options}, [], 'and no options' );
my $plain = human( $tira->question_list( project => $root, ref => $bare->{ref} ) );
like( $plain, qr/Plain one\?/, 'and still renders' );
unlike( $plain, qr/_Why:_\s*\n/, 'without an empty reason line' );

# An empty reason is the same as none, rather than a blank line in the output.
my $blank = $tira->question_add(
    project => $root, ref => $bare->{ref}, text => 'Blank reason?', reason => '   ', options => [ '', 'Real' ] );
ok( !defined $blank->{reason}, 'whitespace is not a reason' );
is_deeply( $blank->{options}, ['Real'], 'and an empty option is dropped rather than numbered' );

done_testing;

__END__

=head1 NAME

61-question-human.t - the human view of questions

=head1 DESCRIPTION

Reported by the developer-dashboard project, which uses these commands
as its only way of asking its owner things. A question list carries a
card reference, so the renderer took it for a record and drew an empty
card with four warnings and no questions at all, while the JSON was
correct throughout. The people these commands exist for read the human
view, so that was the whole workflow failing to reach its reader.
Proves the questions, their answers and the instruction all render, a
card with none says so, and no human render warns.

=cut
