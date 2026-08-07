#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Encode qw(decode_utf8 encode_utf8);
use HTTP::Request::Common qw(GET POST);
use JSON::PP qw(decode_json);
use Plack::Test;
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'dialog' );
my $tira = Tira->new( clock => sub { '2026-08-06T15:00:00+0100' } );
$tira->create_project( name => 'Dialog project', dir => $root );
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
like( $live_html, qr/card-linkage-table/, 'linkage renders as a table-style list (CA21)' );
like( $live_html, qr/card-linkage__title/, 'linkage rows carry the linked title' );
like( $live_html, qr/card-linkage__status/, 'linkage rows carry the linked status' );
like( $live_html, qr/priorityRank/, 'linkage rows sort by priority' );
like( $live_html, qr/data-linkage-row/, 'linkage rows are addressable for tooling' );
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

# DD-423: optimistic concurrency through the update provider
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
    update => sub { '{"ok":true}' },
    comment_add => sub { '{"ok":true}' },
    comment_update => sub { '{"ok":true}' },
    comment_remove => sub { '{"ok":true}' },
    people => sub { '[{"id":"ada","name":"Ada"}]' },
    attachment_fetch => sub { return { content => '', content_type => 'text/plain; charset=UTF-8', filename => 'x.txt', inline => 1 } },
    attachment_add => sub { '{"ok":true}' },
    attachment_remove => sub { '{"ok":true}' },
    checklist_add => sub { '{"ok":true}' },
    checklist_update => sub { '{"ok":true}' },
    link_types => sub { '[]' },
    hierarchy_link => sub { '{"ok":true}' },
    hierarchy_unlink => sub { '{"ok":true}' },
    subitem_link => sub { '{"ok":true}' },
    subitem_unlink => sub { '{"ok":true}' },
    link_add => sub { '{"ok":true}' },
    link_remove => sub { '{"ok":true}' },
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
    %providers,
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
