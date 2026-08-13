#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Encode qw(decode_utf8 encode_utf8);
use HTTP::Request::Common qw(GET POST);
use Cpanel::JSON::XS qw(decode_json);
use Plack::Test;
use Test::More;

use lib 'lib', 't/lib';
use GatedApp qw(signed_in);
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'dialog' );
my $tira = Tira->new( clock => sub { '2026-08-06T15:00:00+0100' } );
$tira->create_project( name => 'Dialog project', dir => $root );
$tira->column_add( project => $root, type => 'ticket', name => 'in-progress', label => 'In Progress' );
$tira->person_add( project => $root, id => 'ada', name => 'Ada Lovelace' );
$tira->person_add( project => $root, id => 'bob', name => 'Bob Retired' );
$tira->person_deactivate( project => $root, id => 'bob' );
$tira->create_record( project => $root, type => 'ticket', title => 'Dialog card' );

sub browser_cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err, @calls ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run(
        command => $command, argv => \@argv, tira => $tira,
        browser_server => sub { push @calls, { @_ }; return 1 },
    );
    return ( $status, $out, $err, \@calls );
}

my ( $status, undef, undef, $calls ) =
  browser_cli( 'dashboard.ticket', '--project', $root, '--title', '-o', 'browser' );
is( $status, 0, 'browser dashboard starts with the dialog providers' );

my $live_html = $calls->[0]{render}->();

like( $live_html, qr/card-dialog__sections/,
    'the dialog carries a sectioned body container' );
unlike( $live_html, qr/JSON\.stringify\(record,\s*null/,
    'the dialog never renders the record as one JSON blob' );
like( $live_html, qr/renderCard/, 'the dialog builds its sections from the record' );
like( $live_html, qr/card-status/, 'the dialog header offers the column dropdown' );
like( $live_html, qr/querySelector\("\.column__name"\)/,
    'the column dropdown labels come from the column name, not the whole header' );
like( $live_html, qr/class="board-filter"/, 'the board control offers a keyword filter' );
like( $live_html, qr{fetch\("/search\?text="}, 'the filter asks the server, so it matches beyond the visible title' );
unlike( $live_html, qr{fetch\("/search\?type="},
    'and asks about the whole project rather than one board, because a question reference can name a card on any of them' );
like( $live_html, qr/document\.querySelectorAll\("\[data-filter\]"\)\.forEach/,
    'every board box shows the same text, since there is only one filter' );
like( $live_html, qr/const pageSize=10;/, 'columns start with ten cards' );
like( $live_html, qr/Show "\+Math\.min\(remaining,pageSize\)\+" more of "\+remaining/,
    'and offer to reveal the next ten, saying how many remain' );
like( $live_html, qr/data-add-card=/, 'each column offers an add-card control' );
like( $live_html, qr/const openNewCard=/, 'the dialog has a new-card mode' );
like( $live_html, qr/reference assigned on save/, 'new cards show no ref until they are saved' );
like( $live_html, qr/fetch\("\/create"/, 'creating posts to the create route' );
like( $live_html, qr/A title is required/, 'only the title is mandatory, and it is enforced' );
like( $live_html, qr/dialog\.querySelector\("\.card-new"\)/,
    'a half-filled new card counts as active editing, so refresh never wipes it' );
like( $live_html, qr/if\(!dialog\.dataset\.ref\)return/,
    'the refresh cycle skips a dialog that has no record yet' );
like( $live_html, qr/card-linkage-table/, 'linkage renders as a table-style list (CA21)' );
like( $live_html, qr/card-linkage__title/, 'linkage rows carry the linked title' );
like( $live_html, qr/card-linkage__status/, 'linkage rows carry the linked status' );
like( $live_html, qr/priorityRank/, 'linkage rows sort by priority' );
like( $live_html, qr/data-linkage-row/, 'linkage rows are addressable for tooling' );
like( $live_html, qr/lastDialogRecordJson/, 'the dialog keeps a rendered-content snapshot' );
like( $live_html, qr/JSON\.stringify\(record\)===lastDialogRecordJson/,
    'an identical refresh repaints nothing' );
like( $live_html, qr/\|\|dialogEditingActive\(\)\)return/,
    'the editing guard re-checks after the refresh fetch returns' );
for my $section (qw(Details Description Checklist Comments)) {
    like( $live_html, qr/\Q$section\E/, "the dialog knows the $section section" );
}
like( $live_html, qr{fetch\("/people"}, 'the dialog loads the author choices from /people' );
like( $live_html, qr{mutate\("/update"}, 'field edits post to the update route' );
like( $live_html, qr/base:base/, 'field saves carry the base value they loaded' );
like( $live_html, qr/result\.conflict/, 'the dialog distinguishes conflict responses' );
like( $live_html, qr/changed while you were editing/, 'conflict messaging explains the retry' );
like( $live_html, qr{mutate\("/comment/add"}, 'comment creation posts to its route' );
like( $live_html, qr{mutate\("/comment/update"}, 'comment editing posts to its route' );
like( $live_html, qr{mutate\("/comment/remove"}, 'comment deletion posts to its route' );

for my $provider (qw(update comment_add comment_update comment_remove people)) {
    is( ref $calls->[0]{$provider}, 'CODE', "browser server receives a $provider provider" );
}

my $people = decode_json( $calls->[0]{people}->() );
is( scalar @{$people}, 1, 'the people provider lists only active people' );
is( $people->[0]{id}, 'ada', 'the active person id is served' );
is( $people->[0]{name}, 'Ada Lovelace', 'the active person name is served' );

my $updated = decode_json(
    $calls->[0]{update}->( { ref => 'TKT-001', field => 'title', value => 'Renamed card' } )
);
ok( $updated->{ok}, 'the update provider succeeds for a valid field' );
is( $updated->{record}{title}, 'Renamed card', 'the update provider persists through record_update' );
is( $tira->record_show( project => $root, ref => 'TKT-001' )->{title},
    'Renamed card', 'the field edit reached the record file' );

my $priority = decode_json(
    $calls->[0]{update}->( { ref => 'TKT-001', field => 'priority', value => '4' } )
);
is( $priority->{record}{priority}, 4, 'priority edits pass engine validation' );

my $error = eval { $calls->[0]{update}->( { ref => 'TKT-001', field => 'priority', value => '9' } ); 1 } ? '' : $@;
like( $error, qr/Priority/, 'an invalid priority is rejected by the engine' );

$error = eval { $calls->[0]{update}->( { ref => 'TKT-001', field => 'assignee', value => 'bob' } ); 1 } ? '' : $@;
like( $error, qr/inactive|not.*active|unknown/i, 'an inactive assignee is rejected by the engine' );

$error = eval { $calls->[0]{update}->( { ref => 'TKT-001', field => 'comments', value => [] } ); 1 } ? '' : $@;
like( $error, qr/Field 'comments' is not editable/, 'non-editable fields are refused by name' );

$error = eval { $calls->[0]{update}->( { ref => 'TKT-001' } ); 1 } ? '' : $@;
like( $error, qr/Update payload requires/, 'update payloads must carry a field and value' );

my $pound = chr 0xA3;
my $added = decode_json( encode_utf8(
    $calls->[0]{comment_add}->( { ref => 'TKT-001', author => 'ada', text => "Costs ${pound}9" } )
) );
ok( $added->{ok}, 'the comment add provider succeeds' );
is( $added->{comment}{id}, 'CMT-001', 'the new comment id is returned' );
is( $added->{comment}{body}, "Costs ${pound}9", 'UTF-8 comment bodies survive the provider' );

$error = eval { $calls->[0]{comment_add}->( { ref => 'TKT-001', author => 'bob', text => 'no' } ); 1 } ? '' : $@;
like( $error, qr/inactive|not.*active/i, 'inactive authors cannot comment' );

my $edited = decode_json(
    $calls->[0]{comment_update}->( { ref => 'TKT-001', comment => 'CMT-001', text => 'Edited body' } )
);
is( $edited->{comment}{body}, 'Edited body', 'the comment update provider edits the body' );

my $removed = decode_json(
    $calls->[0]{comment_remove}->( { ref => 'TKT-001', comment => 'CMT-001' } )
);
ok( $removed->{ok}, 'the comment remove provider succeeds' );
is( $removed->{removed}{id}, 'CMT-001', 'the removed comment is reported' );
is( scalar @{ $tira->comment_list( project => $root, ref => 'TKT-001' ) },
    0, 'browser comment removal persists to the record file' );

for my $payload ( undef, [], { ref => 'TKT-001' } ) {
    $error = eval { $calls->[0]{comment_remove}->($payload); 1 } ? '' : $@;
    like( $error, qr/payload|requires/i, 'malformed comment removal payloads are refused' );
}

# The board filter asks the engine, so it matches description text too
my $filter_hits = decode_json( $calls->[0]{search}->( { type => 'ticket', text => 'Renamed' } ) );
is( ref $filter_hits, 'ARRAY', 'the search provider returns a flat ref list' );
ok( scalar( grep { $_ eq 'TKT-001' } @{$filter_hits} ), 'it finds the matching card' );
is_deeply( decode_json( $calls->[0]{search}->( { type => 'ticket', text => 'nothingmatchesthis' } ) ), [],
    'a query with no matches returns an empty list, not everything' );
is_deeply( decode_json( $calls->[0]{search}->( { text => '' } ) ), [],
    'an empty query returns nothing rather than the whole board' );
is_deeply( decode_json( $calls->[0]{search}->( {} ) ), [], 'a missing query is handled the same way' );

# The board reads and writes its own column layout
my $layout = decode_json( $calls->[0]{columns}->( { type => 'ticket' } ) );
is( ref $layout, 'ARRAY', 'the columns provider returns the board layout' );
ok( scalar( grep { $_->{name} eq 'backlog' } @{$layout} ), 'including the protected columns' );
ok( exists $layout->[0]{watched}, 'and whether each column is watched' );

my $reordered = decode_json(
    $calls->[0]{column_apply}->( {
        type => 'ticket',
        columns => [ reverse map { { name => $_->{name} } } @{$layout} ],
    } )
);
is_deeply( $reordered->{added}, [], 'applying a reordering adds nothing' );
ok( $reordered->{reordered}, 'and reports that it reordered' );
is( $tira->column_list( project => $root, type => 'ticket' )->[0]{name},
    $layout->[-1]{name}, 'the board really is in the new order' );
$calls->[0]{column_apply}->( { type => 'ticket', columns => [ map { { name => $_->{name} } } @{$layout} ] } );

for my $payload ( undef, [], { type => 'ticket' }, { type => 'ticket', columns => {} } ) {
    $error = eval { $calls->[0]{column_apply}->($payload); 1 } ? '' : $@;
    like( $error, qr/layout|object/i, 'a malformed column layout is refused' );
}

# The live refresh rebuilds every card, so if its payload omits the
# waiting flag the yellow the page was served with is wiped a second later.
{
    my $asked = $tira->question_add(
        project => $root, ref => 'TKT-001', text => 'Does the refresh keep the colour?' );
    my $refreshed = decode_json( $calls->[0]{data}->() );
    my ($card) = grep { $_->{ref} eq 'TKT-001' }
      map { @{$_} } values %{ $refreshed->{ticket} };
    ok( $card, 'the refresh payload carries the card' );
    ok( $card->{waiting}, 'and says it is waiting, so the colour survives the refresh' );
    $tira->question_discard( project => $root, id => $asked->{id} );
}

# Questions sat under the comments, so on a card with twenty of them
# the one section needing an answer was the furthest to scroll to.
like( $live_html, qr/box\.dataset\.section=title\.toLowerCase\(\)/,
    'each section is named, so one can be found without matching its heading text' );
like( $live_html, qr/sectionsHost\.insertBefore\(section\("Questions",host\)/,
    'and the questions are placed rather than appended at the end' );
like( $live_html, qr/\(details&&details\.nextSibling\)\|\|comments\|\|null/,
    'right after what the card is, because a dozen sections sit between the top and the comments' );
unlike( $live_html, qr/sectionsHost\.appendChild\(section\("Questions"/,
    'with nothing left that would put them back at the bottom' );

# The box waits behind Other, and a display rule would otherwise beat the
# hidden attribute and leave it on screen - which is exactly what it did until
# somebody looked at the panel rather than at the tests.
like( $live_html, qr/\.card-question__typed\[hidden\][^}]*\{display:none\}/,
    'hiding the answer box actually hides it' );

# Evidence where the question is, and a place to drop more.
like( $live_html, qr/fileList\(question\.attachments,"Asked with:"\)/,
    'what the question was asked with is shown on it' );
like( $live_html, qr/fileList\(question\.answer&&question\.answer\.attachments,"Answered with:"\)/,
    'and what came back with the answer, under the same question' );
like( $live_html, qr/card-question__drop/, 'with somewhere to drop another file' );
like( $live_html, qr{mutate\("/question/attach"}, 'which uploads it against that question' );
like( $live_html, qr/to:question\.answer\?"answer":"question"/,
    'onto the answer once there is one, since that is who is attaching by then' );
like( $live_html, qr/box\.style\.height=Math\.min\(box\.scrollHeight,420\)\+"px"/,
    'and the answer box grows with what is typed rather than hiding the start of it' );

# a question that has been set aside cannot be added to, so offering a
# place to drop a file on one offers something that does nothing. Its existing
# files still show, because they still happened.
like( $live_html, qr/if\(!question\.discarded_at\)\{const drop=el\("div","card-question__drop"/,
    'the drop zone is only offered on a question that can still be added to' );
like( $live_html, qr/fileList\(question\.attachments,"Asked with:"\)/,
    'while the files already on it are listed whatever its state' );
like( $live_html, qr/if\(!files\|\|!files\.length\)return/,
    'and a question with no files shows no file area at all' );

# What still needs doing comes first, what is finished sinks.
like( $live_html, qr/const questionRank=question=>question\.discarded_at\?3:!question\.answer\?0:!question\.answer\.mark\?1:2/,
    'unanswered ranks first, then answered but unjudged, then judged, then set aside' );
like( $live_html, qr/all\.sort\(\(a,b\)=>questionRank\(a\)-questionRank\(b\)\)/,
    'and the panel is ordered by it' );
like( $live_html, qr/const all=\[\.\.\.\(record\.questions\|\|\[\]\)\]/,
    'on a copy, so sorting for display never reorders the card itself' );

# a judged question is finished business. It keeps the question, the
# answer and the verdict as an icon, and drops the apparatus for acting on it,
# which is only in the way once there is nothing left to do.
like( $live_html, qr/const settled=!!\(question\.answer&&question\.answer\.mark\)/,
    'a question counts as settled once its answer carries a mark' );
like( $live_html, qr/card-question__verdict/, 'which is shown as a verdict rather than a word' );
like( $live_html, qr/question\.answer\.mark==="ok"\?"\\u2705":"\\u274c"/,
    'a tick or a cross, written as escapes so they cannot arrive double-encoded' );
like( $live_html, qr/if\(settled\)\{block\.appendChild\(el\("blockquote","card-question__answer",question\.answer\.text\)\);host\.appendChild\(block\);return\}/,
    'and a settled question stops there: question, answer, verdict, nothing else' );
like( $live_html, qr/\.card-question\[data-settled="1"\]\{padding:\.5rem/,
    'drawn tighter than one still needing attention' );

# Answering wiped the whole questions panel. The reload rebuilds the
# card's sections from scratch, so anything only the first render added is gone
# the moment anybody changes something.
like( $live_html, qr/renderCard\(record\);renderQuestions\(record\);renderPoliceLog\(record\);renderWorkLog\(record\);return record/,
    'reloading the card rebuilds its questions and its work log too, so answering does not erase them' );
# Three paths, not two. The background refresh rendered only the card, which
# wipes the sections the other two draw into - so the questions and the work log
# vanished on every refresh, and a work log somebody had open never showed them
# what had just happened. That was the fault the owner could see and no
# assertion here could.
is( scalar( () = $live_html =~ /renderQuestions\(record\)/g ), 3,
    'and every path that renders a card renders them: the first open, every reload, and every refresh' );
like( $live_html, qr/renderCard\(record\);renderQuestions\(record\);renderPoliceLog\(record\);renderWorkLog\(record\)\}\)\.catch/,
    'including the background refresh, which used to redraw the card alone' );

# --- the work log, collapsed and fetched only when asked for --------------

# A card has a great deal happen to it. Loading all of it whenever a card is
# opened would bury everything else, so the section renders closed and the
# request only goes out when somebody expands it - which is also the whole
# difference between a card that opens instantly and one that does not.
like( $live_html, qr/const renderWorkLog=/, 'the dialog builds a work log section' );
like( $live_html, qr/card-worklog__toggle/, 'with something to click' );
like( $live_html, qr/let worklogOpen=false/, 'starting closed' );
like( $live_html, qr/body\.hidden=!worklogOpen/, 'and drawn closed unless somebody had it open' );
like( $live_html, qr/if\(!open\|\|loaded\)return/,
    'and it fetches once, on expanding, rather than on every click' );

{
    # The request must be reached from the click handler and from nowhere that
    # runs while a card is merely being opened. If it were anywhere else the
    # section would look lazy while loading eagerly, which is the failure that
    # would never show up by reading the rendered page.
    my ($handler) = $live_html =~ /head\.addEventListener\("click",\(\)=>\{(.*?)\}\);if\(worklogOpen\)/s;
    ok( $handler, 'the toggle has a click handler' );
    like( $handler // '', qr/readLog\(\)/,
        'which is what reads the log, so opening a card asks for nothing' );

    # One place fetches it, so there is one place to be wrong about when.
    my $fetches = () = $live_html =~ m{fetch\("/worklog\?ref="}g;
    is( $fetches, 1, 'and exactly one place in the page fetches a work log' );
}

# It renders into the sections host, so it scrolls with everything else. Put
# outside it, the section pinned itself to the bottom of the dialog and cut off
# whatever was above - which every assertion in this file passed straight
# through, and only looking at the screen caught.
like( $live_html, qr/const host=sectionsHost/,
    'the work log renders among the sections rather than beside them' );
unlike( $live_html, qr/<div class="card-worklog"><\/div>/,
    'with no host of its own outside the scrolling area' );

# The owner reads and answers questions where he reads the card
like( $live_html, qr/const renderQuestions=/, 'the dialog builds a questions section' );

# The owner named five things this panel must carry.
like( $live_html, qr/card-question__text/, 'one: the question itself' );
like( $live_html, qr/card-question__choice/, 'two: its choices' );
like( $live_html, qr/card-question__reason/, 'three: why it was asked' );
like( $live_html, qr/card-question__status/, 'four: its status' );
like( $live_html, qr/question\.discarded_at\?"discarded"/,
    'including discarded, which is one of the three he named' );
like( $live_html, qr{mutate\("/question/answer"}, 'five: an answer can be added' );
like( $live_html, qr/question\.answer\?"Save answer":"Answer"/,
    'and an existing one edited rather than only read' );
like( $live_html, qr/box\.value=question\.answer\?question\.answer\.text:""/,
    'with the current answer loaded for editing' );

# Picking a choice is the whole answer; typing is only for anything else.
like( $live_html, qr/pick\.onclick=\(\)=>answerWith\(choice\)/,
    'clicking a choice answers with it in one click' );
like( $live_html, qr/Other\\u2026/, 'with an Other button for a different answer' );
like( $live_html, qr/typed\.hidden=/, 'and the box stays out of the way until it is wanted' );
like( $live_html, qr{mutate\("/question/mark"}, 'and the owner can say whether it settles it' );

# A discarded question is shown struck through rather than hidden.
like( $live_html, qr/const all=\[\.\.\.\(record\.questions\|\|\[\]\)\]/,
    'every question is rendered, discarded ones included' );
like( $live_html, qr/card-question\[data-status="discarded"\] \.card-question__text\{text-decoration:line-through\}/,
    'and a discarded one is struck through' );

my $board_question = $tira->question_add(
    project => $root, ref => 'TKT-001', text => 'Asked from the board test' );
my $answered_from_board = decode_json(
    $calls->[0]{question_answer}->( { id => $board_question->{id}, text => 'From the board' } ) );
ok( $answered_from_board->{ok}, 'the answer provider succeeds' );
is( $answered_from_board->{question}{answer}{text}, 'From the board',
    'and the answer really lands on the question' );
ok( decode_json( $calls->[0]{question_mark}->(
        { id => $board_question->{id}, mark => 'ok' } ) )->{ok},
    'and it can be marked from the board' );
for my $payload ( undef, [], { id => $board_question->{id} } ) {
    $error = eval { $calls->[0]{question_answer}->($payload); 1 } ? '' : $@;
    like( $error, qr/question|text/i, 'a malformed answer payload is refused' );
}
for my $payload ( undef, [], { id => $board_question->{id} } ) {
    $error = eval { $calls->[0]{question_mark}->($payload); 1 } ? '' : $@;
    like( $error, qr/question|mark/i, 'a malformed mark payload is refused' );
}

# Creating a card from a column through the browser
my $made = decode_json(
    $calls->[0]{create}->( { type => 'ticket', column => 'in-progress', title => 'Made from the board' } )
);
ok( $made->{ok}, 'the create provider succeeds' );
like( $made->{record}{ref}, qr/\ATKT-\d+\z/, 'a reference is assigned on creation' );
is( $made->{record}{column}, 'in-progress', 'the card is created in the column that asked for it' );
is( $made->{record}{title}, 'Made from the board', 'the supplied title is stored' );
is( $tira->record_show( project => $root, ref => $made->{record}{ref} )->{title},
    'Made from the board', 'creation persists to the filesystem' );

my $optional = decode_json(
    $calls->[0]{create}->( {
        type => 'ticket', column => 'backlog', title => 'With detail',
        description => 'Filled in', priority => '4', assignee => 'ada',
    } )
);
is( $optional->{record}{description}, 'Filled in', 'optional fields are stored when given' );
is( $optional->{record}{priority}, 4, 'priority is stored as a number' );
is( $optional->{record}{assignee}, 'ada', 'assignee is stored' );

my $blank = decode_json(
    $calls->[0]{create}->( {
        type => 'ticket', column => 'backlog', title => 'Only a title',
        description => '', priority => '', assignee => '',
    } )
);
ok( !defined $blank->{record}{priority}, 'empty optional fields are left unset, not stored as blanks' );
is( $blank->{record}{description}, '', 'an empty description stays empty' );

$error = eval { $calls->[0]{create}->( { type => 'ticket', column => 'backlog' } ); 1 } ? '' : $@;
like( $error, qr/requires type, column, and title/, 'the title is mandatory' );
$error = eval { $calls->[0]{create}->( { type => 'ticket', column => 'nowhere', title => 'X' } ); 1 } ? '' : $@;
like( $error, qr/Column 'nowhere' not found/, 'an unknown column is refused by the engine' );
$error = eval { $calls->[0]{create}->( { type => 'ticket', column => 'backlog', title => 'X', assignee => 'bob' } ); 1 } ? '' : $@;
like( $error, qr/bob/, 'an unknown assignee is refused' );
$error = eval { $calls->[0]{create}->('nope'); 1 } ? '' : $@;
like( $error, qr/payload must be an object/, 'malformed create payloads are refused' );

# Optimistic concurrency through the update provider
my $cas = decode_json(
    $calls->[0]{update}->( { ref => 'TKT-001', field => 'title', value => 'CAS write', base => 'Renamed card' } )
);
ok( $cas->{ok}, 'a matching base saves through the provider' );
is( $cas->{record}{title}, 'CAS write', 'the compare-and-swap value persists' );

$error = eval { $calls->[0]{update}->( { ref => 'TKT-001', field => 'title', value => 'Lost write', base => 'Renamed card' } ); 1 } ? '' : $@;
like( $error, qr/\AConflict: title changed while you were editing/, 'a stale base is refused with a conflict error' );
is( $tira->record_show( project => $root, ref => 'TKT-001' )->{title},
    'CAS write', 'the conflicted save writes nothing' );

$error = eval { $calls->[0]{update}->( { ref => 'TKT-001', field => 'title', value => 'x', base => ['nope'] } ); 1 } ? '' : $@;
like( $error, qr/plain value/, 'structured bases are refused' );

my %providers = (
    render => sub { '<!doctype html>' }, data => sub { '{}' },
    move => sub { '{}' }, detail => sub { '{}' },
    search => sub { '[]' },
    columns => sub { '[]' },
    question_answer => sub { '{"ok":true}' },
    question_mark => sub { '{"ok":true}' },
    question_attach => sub { '{"ok":true}' },
    column_apply => sub { '{}' },
    create => sub { '{"ok":true,"record":{"ref":"TKT-009"}}' },
    update => sub { '{"ok":true}' },
    comment_add => sub { '{"ok":true}' },
    comment_update => sub { '{"ok":true}' },
    comment_remove => sub { '{"ok":true}' },
    people => sub { '[{"id":"ada","name":"Ada"}]' },
    attachment_fetch => sub { return { content => '', content_type => 'text/plain; charset=UTF-8', filename => 'x.txt', inline => 1 } },
    attachment_add => sub { '{"ok":true}' },
    attachment_remove => sub { '{"ok":true}' },
    attachment_discard => sub { '{"ok":true}' },
    checklist_add => sub { '{"ok":true}' },
    checklist_update => sub { '{"ok":true}' },
    link_types => sub { '[]' },
    hierarchy_link => sub { '{"ok":true}' },
    hierarchy_unlink => sub { '{"ok":true}' },
    subitem_link => sub { '{"ok":true}' },
    subitem_unlink => sub { '{"ok":true}' },
    link_add => sub { '{"ok":true}' },
    link_remove => sub { '{"ok":true}' },
    police_log => sub { '[]' },
);

for my $missing (qw(update comment_add comment_update comment_remove people)) {
    my %incomplete = %providers;
    delete $incomplete{$missing};
    eval { Tira::DashboardWeb->build_psgi_app(%incomplete) };
    ( my $label = $missing ) =~ tr/_/ /;
    like( $@, qr/Missing dashboard \Q$label\E provider/, "PSGI builder requires the $missing provider" );
}

my %received;
my $app = Tira::DashboardWeb->build_psgi_app(
    signed_in(),
    %providers,
    search => sub { $received{search} = $_[0]; return '["TKT-001"]' },
    columns => sub { $received{columns} = $_[0]; return '[{"name":"backlog","label":"Backlog","protected":true,"watched":1}]' },
    question_answer => sub { $received{question_answer} = $_[0]; return '{"ok":true}' },
    question_mark => sub { $received{question_mark} = $_[0]; return '{"ok":true}' },
    question_attach => sub { $received{question_attach} = $_[0]; return '{"ok":true}' },
    column_apply => sub { $received{column_apply} = $_[0]; return '{"added":[],"removed":[],"reordered":false}' },
    create => sub { $received{create} = $_[0]; return '{"ok":true,"record":{"ref":"TKT-009"}}' },
    update => sub {
        $received{update} = $_[0];
        die "Conflict: title changed while you were editing\n" if ( $_[0]{base} // '' ) eq 'STALE';
        return '{"ok":true,"record":{"title":"\\u00a3"}}';
    },
    comment_add => sub { $received{comment_add} = $_[0]; return '{"ok":true,"comment":{"id":"CMT-001"}}' },
    comment_update => sub { $received{comment_update} = $_[0]; return '{"ok":true,"comment":{"id":"CMT-001"}}' },
    comment_remove => sub { $received{comment_remove} = $_[0]; die "Comment 'CMT-404' not found\n" },
    people => sub { '[{"id":"ada","name":"Ada \\u00a3"}]' },
);

test_psgi $app, sub {
    my ($client) = @_;

    my $people_response = $client->( GET '/people' );
    is( $people_response->code, 200, 'the people route responds' );
    like( $people_response->header('Content-Type'), qr{application/json}, 'people are JSON' );
    is( decode_json( $people_response->content )->[0]{name}, "Ada $pound",
        'the people route returns UTF-8 JSON bytes' );

    my $update_response = $client->(
        POST '/update', Content_Type => 'application/json',
        Content => encode_utf8( qq({"ref":"TKT-001","field":"title","value":"New ${pound} title"}) ),
    );
    is( $update_response->code, 200, 'the update route responds' );
    is( decode_json( $update_response->content )->{record}{title}, $pound,
        'the update route returns the provider result' );
    is( $received{update}{value}, "New ${pound} title", 'the update payload decodes UTF-8 text' );

    my $search_response = $client->( GET '/search?type=ticket&text=hello%20world' );
    is( $search_response->code, 200, 'the search route responds' );
    like( $search_response->header('Content-Type'), qr{application/json}, 'filter results are JSON' );
    is( $received{search}{text}, 'hello world', 'the query is decoded from the URL' );
    is( $received{search}{type}, 'ticket', 'the board type is passed through' );

    my $create_response = $client->(
        POST '/create', Content_Type => 'application/json',
        Content => '{"type":"ticket","column":"backlog","title":"Routed"}',
    );
    is( $create_response->code, 200, 'the create route responds' );
    is( $received{create}{title}, 'Routed', 'the create payload is delivered' );

    my $add_response = $client->(
        POST '/comment/add', Content_Type => 'application/json',
        Content => '{"ref":"TKT-001","author":"ada","text":"hello"}',
    );
    is( $add_response->code, 200, 'the comment add route responds' );
    is( $received{comment_add}{author}, 'ada', 'the comment add payload is delivered' );

    my $edit_response = $client->(
        POST '/comment/update', Content_Type => 'application/json',
        Content => '{"ref":"TKT-001","comment":"CMT-001","text":"edited"}',
    );
    is( $edit_response->code, 200, 'the comment update route responds' );
    is( $received{comment_update}{comment}, 'CMT-001', 'the comment update payload is delivered' );

    my $remove_response = $client->(
        POST '/comment/remove', Content_Type => 'application/json',
        Content => '{"ref":"TKT-001","comment":"CMT-404"}',
    );
    is( $remove_response->code, 422, 'a failing mutation returns an unprocessable status' );
    my $failure = decode_json( $remove_response->content );
    ok( !$failure->{ok}, 'the failing mutation reports ok false' );
    like( $failure->{error}, qr/CMT-404.*not found/, 'the failing mutation carries the engine error' );
    ok( !exists $failure->{conflict}, 'ordinary failures carry no conflict flag' );

    my $conflict_response = $client->(
        POST '/update', Content_Type => 'application/json',
        Content => '{"ref":"TKT-001","field":"title","value":"Mine","base":"STALE"}',
    );
    is( $conflict_response->code, 422, 'a conflicting update returns unprocessable' );
    my $conflict = decode_json( $conflict_response->content );
    ok( !$conflict->{ok}, 'the conflict reports ok false' );
    ok( $conflict->{conflict}, 'the conflict is flagged so the dialog can recover' );
    like( $conflict->{error}, qr/changed while you were editing/, 'the conflict explains itself' );
    is( $received{update}{base}, 'STALE', 'the base travels through the route' );

    my $bad_json = $client->(
        POST '/update', Content_Type => 'application/json', Content => 'not-json',
    );
    is( $bad_json->code, 422, 'malformed JSON bodies fail as unprocessable' );
};

done_testing;

__END__

=head1 NAME

19-dashboard-dialog.t - Jira-style dialog providers and mutation routes

=head1 DESCRIPTION

Guards the sectioned card dialog contract (no JSON blob, section markup,
mutation fetches), the CLI-wired update/comment/people providers with full
engine validation, and the Dancer2 routes' UTF-8 and failure semantics.

=cut
