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
like( $listed, qr/# Questions on \Q$card->{ref}\E/, 'the heading says what this is' );
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
like( $empty, qr/# Questions on \Q$bare->{ref}\E/, 'a card with no questions still names itself' );
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

done_testing;

__END__

=head1 NAME

61-question-human.t - DD-478 the human view of questions

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
