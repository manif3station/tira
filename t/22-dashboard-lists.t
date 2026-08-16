#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Request::Common qw(POST);
use Cpanel::JSON::XS qw(decode_json);
use Plack::Test;
use Test::More;

use lib 'lib', 't/lib';
use GatedApp qw(signed_in);
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'lists' );
my $tira = Tira->new( clock => sub { '2026-08-06T19:00:00+0100' } );
$tira->create_project( name => 'List project', dir => $root );
$tira->create_record(
    project => $root, type => 'ticket', title => 'List card',
    acceptance => ['original criterion'], scope_in => ['dialog'], scope_out => ['reports'],
);
$tira->checklist_add( project => $root, ref => 'TKT-001', item => 'Design rows', status => 'To Do' );

sub browser_cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err, @calls ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run(
        command => $command, argv => \@argv, tira => $tira,
        browser_server => sub { push @calls, { @_ }; return 1 },
    );
    return ( $status, $out, $err, \@calls );
}

my ( $status, undef, undef, $calls ) =
  browser_cli( 'dashboard.ticket', '--title', '-o', 'browser' );
is( $status, 0, 'browser dashboard starts with the list providers' );

for my $provider (qw(checklist_add checklist_update)) {
    is( ref $calls->[0]{$provider}, 'CODE', "browser server receives a $provider provider" );
}

my $live_html = $calls->[0]{render}->();
like( $live_html, qr/card-list--editable/, 'list sections render as editable lists' );
like( $live_html, qr/data-list-add/, 'each list section offers an add control' );
like( $live_html, qr{mutate\("/checklist/add"}, 'new checklist rows post to their route' );
like( $live_html, qr{mutate\("/checklist/update"}, 'checklist edits post to their route' );

my $update = $calls->[0]{update};

my $labels = decode_json( $update->( { ref => 'TKT-001', field => 'labels', value => [ 'Browser', 'dialog' ] } ) );
ok( $labels->{ok}, 'label lists replace through the update provider' );
is_deeply( $labels->{record}{labels}, [ 'Browser', 'dialog' ], 'the replacement list is persisted in order' );

my $criteria = decode_json(
    $update->( { ref => 'TKT-001', field => 'acceptance_criteria', value => ['edited criterion'] } )
);
is_deeply( $criteria->{record}{acceptance_criteria}, ['edited criterion'],
    'acceptance criteria replace as a whole list' );

my $included = decode_json(
    $update->( { ref => 'TKT-001', field => 'scope_included', value => [ 'dialog', 'viewer' ] } )
);
is_deeply( $included->{record}{scope}{included}, [ 'dialog', 'viewer' ], 'scope included replaces its side' );
is_deeply( $included->{record}{scope}{excluded}, ['reports'], 'the other scope side is preserved' );

my $emptied = decode_json( $update->( { ref => 'TKT-001', field => 'bdd', value => [] } ) );
is_deeply( $emptied->{record}{bdd}, [], 'a list field can be emptied' );

my $error = eval { $update->( { ref => 'TKT-001', field => 'labels', value => 'plain' } ); 1 } ? '' : $@;
like( $error, qr/array value/i, 'list fields refuse plain scalar values' );

$error = eval { $update->( { ref => 'TKT-001', field => 'title', value => ['array'] } ); 1 } ? '' : $@;
like( $error, qr/plain value/i, 'single-value fields refuse arrays' );

$error = eval { $update->( { ref => 'TKT-001', field => 'labels', value => [ { bad => 1 } ] } ); 1 } ? '' : $@;
like( $error, qr/plain text items/i, 'list values must be plain text items' );

$error = eval { $update->( { ref => 'TKT-001', field => 'linkage', value => [] } ); 1 } ? '' : $@;
like( $error, qr/not editable/i, 'linkage stays uneditable from the dialog' );

my $added = decode_json( $calls->[0]{checklist_add}->( { ref => 'TKT-001', item => 'Prove rows', status => 'To Do' } ) );
ok( $added->{ok}, 'the checklist add provider succeeds' );
is( $added->{entry}{id}, 'CHK-002', 'new checklist entries keep monotonic ids' );

my $edited = decode_json(
    $calls->[0]{checklist_update}->( { ref => 'TKT-001', id => 'CHK-001', status => 'Done' } )
);
is( $edited->{entry}{status}, 'Done', 'the checklist update provider edits status' );
is( $edited->{entry}{item}, 'Design rows', 'unchanged checklist item text survives' );

$error = eval { $calls->[0]{checklist_add}->( { ref => 'TKT-001', item => 'x' } ); 1 } ? '' : $@;
like( $error, qr/requires/i, 'checklist add payloads need item and status' );
$error = eval { $calls->[0]{checklist_update}->( { ref => 'TKT-001', id => 'CHK-009', status => 'x' } ); 1 } ? '' : $@;
like( $error, qr/not found/i, 'unknown checklist ids fail clearly' );

my %providers = (
    signed_in(),
    render => sub { '<!doctype html>' }, data => sub { '{}' },
    move => sub { '{}' }, detail => sub { '{}' },
    search => sub { '[]' },
    columns => sub { '[]' },
    question_answer => sub { '{"ok":true}' },
    question_mark => sub { '{"ok":true}' },
    question_attach => sub { '{"ok":true}' },
    column_apply => sub { '{}' },
    create => sub { '{"ok":true,"record":{"ref":"TKT-009"}}' },
    update => sub { '{"ok":true}' }, comment_add => sub { '{"ok":true}' },
    comment_update => sub { '{"ok":true}' }, comment_remove => sub { '{"ok":true}' },
    people => sub { '[]' },
    attachment_fetch => sub { return {} }, attachment_add => sub { '{"ok":true}' },
    attachment_remove => sub { '{"ok":true}' },
    attachment_discard => sub { '{"ok":true}' },
    checklist_add => sub { return '{"ok":true,"entry":{"id":"CHK-001"}}' },
    checklist_update => sub { die "Checklist entry 'CHK-404' not found\n" },
    link_types => sub { '[]' },
    hierarchy_link => sub { '{"ok":true}' },
    hierarchy_unlink => sub { '{"ok":true}' },
    subitem_link => sub { '{"ok":true}' },
    subitem_unlink => sub { '{"ok":true}' },
    link_add => sub { '{"ok":true}' },
    link_remove => sub { '{"ok":true}' },
    police_log => sub { '[]' },
);

for my $missing (qw(checklist_add checklist_update)) {
    my %incomplete = %providers;
    delete $incomplete{$missing};
    eval { Tira::DashboardWeb->build_psgi_app(%incomplete) };
    ( my $label = $missing ) =~ tr/_/ /;
    like( $@, qr/Missing dashboard \Q$label\E provider/, "PSGI builder requires the $missing provider" );
}

my $app = Tira::DashboardWeb->build_psgi_app(%providers);
test_psgi $app, sub {
    my ($client) = @_;
    my $add = $client->(
        POST '/checklist/add', Content_Type => 'application/json',
        Content => '{"ref":"TKT-001","item":"row","status":"To Do"}',
    );
    is( $add->code, 200, 'the checklist add route responds' );
    ok( decode_json( $add->content )->{ok}, 'the add route returns the provider result' );

    my $edit = $client->(
        POST '/checklist/update', Content_Type => 'application/json',
        Content => '{"ref":"TKT-001","id":"CHK-404","status":"x"}',
    );
    is( $edit->code, 422, 'a failing checklist edit is unprocessable' );
    like( decode_json( $edit->content )->{error}, qr/CHK-404.*not found/,
        'the checklist failure carries the engine error' );
};

done_testing;

__END__

=head1 NAME

22-dashboard-lists.t - dialog list-field editing and checklist management

=head1 DESCRIPTION

Guards array-valued /update semantics for list fields (whole-list replacement,
scope side preservation, strict item validation, linkage exclusion), the
checklist add/update providers and routes, and the editable-list dialog markup.

=cut
