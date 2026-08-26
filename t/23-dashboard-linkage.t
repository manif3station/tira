#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
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
my $root = File::Spec->catdir( $tmp, 'linkage' );
my $tira = Tira->new( clock => sub { '2026-08-06T20:00:00+0100' } );
$tira->create_project( name => 'Linkage project', dir => $root );
$tira->create_record( project => $root, type => 'sow', title => 'Umbrella' );
$tira->create_record( project => $root, type => 'epic', title => 'Feature epic' );
$tira->create_record( project => $root, type => 'ticket', title => 'Master ticket' );
$tira->create_record( project => $root, type => 'ticket', title => 'Sub ticket' );
$tira->create_record( project => $root, type => 'ticket', title => 'Blocking ticket' );

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
is( $status, 0, 'browser dashboard starts with the linkage providers' );

for my $provider (qw(link_types hierarchy_link hierarchy_unlink subitem_link subitem_unlink link_add link_remove)) {
    is( ref $calls->[0]{$provider}, 'CODE', "browser server receives a $provider provider" );
}

my $live_html = $calls->[0]{render}->();
like( $live_html, qr{fetch\("/link-types"}, 'link type choices load from their route' );
like( $live_html, qr{"/hierarchy/link"}, 'hierarchy linking posts to its route' );
like( $live_html, qr{"/hierarchy/unlink"}, 'hierarchy unlinking posts to its route' );
like( $live_html, qr{"/subitem/link"}, 'subitem linking posts to its route' );
like( $live_html, qr{mutate\("/link/add"}, 'typed link creation posts to its route' );
like( $live_html, qr{mutate\("/link/remove"}, 'typed link removal posts to its route' );
like( $live_html, qr/card-linkage/, 'the linkage section renders interactive rows' );
like( $live_html, qr/sectionWithEdit/, 'long-text sections place their pencil in the heading' );
like( $live_html, qr/\@media\(max-width:520px\)/, 'a small-screen media query exists' );

my $types = decode_json( $calls->[0]{link_types}->() );
ok( scalar @{$types} >= 1, 'link types are served' );
ok( ( grep { $_->{outward} eq 'blocks' && $_->{inward} eq 'is-blocked-by' } @{$types} ),
    'the protected blocks pair is present' );

my $linked = decode_json( $calls->[0]{hierarchy_link}->( { parent => 'SOW-001', child => 'EPC-001' } ) );
ok( $linked->{ok}, 'hierarchy linking succeeds through the provider' );
is( $tira->record_show( project => $root, ref => 'EPC-001' )->{linkage}{sow_ref},
    'SOW-001', 'the epic gained its SOW parent' );

my $error = eval { $calls->[0]{hierarchy_link}->( { parent => 'SOW-001', child => 'TKT-001' } ); 1 } ? '' : $@;
like( $error, qr/SOW-to-epic or epic-to-ticket/, 'invalid hierarchy pairs are refused by the engine' );

my $unlinked = decode_json( $calls->[0]{hierarchy_unlink}->( { parent => 'SOW-001', child => 'EPC-001' } ) );
ok( $unlinked->{ok}, 'hierarchy unlinking succeeds through the provider' );
ok( !defined $tira->record_show( project => $root, ref => 'EPC-001' )->{linkage}{sow_ref},
    'the epic parent is cleared' );

my $sub = decode_json( $calls->[0]{subitem_link}->( { parent => 'TKT-001', child => 'TKT-002' } ) );
ok( $sub->{ok}, 'subitem linking succeeds through the provider' );
is( $tira->record_show( project => $root, ref => 'TKT-002' )->{linkage}{parent_ticket_ref},
    'TKT-001', 'the sub ticket gained its master' );
my $unsub = decode_json( $calls->[0]{subitem_unlink}->( { parent => 'TKT-001', child => 'TKT-002' } ) );
ok( $unsub->{ok}, 'subitem unlinking succeeds through the provider' );

my $added = decode_json( $calls->[0]{link_add}->( { from => 'TKT-001', type => 'blocks', to => 'TKT-003' } ) );
ok( $added->{ok}, 'typed link creation succeeds through the provider' );
is( $added->{link}{reciprocal}, 'is-blocked-by', 'the reciprocal type is reported' );
is( $tira->record_show( project => $root, ref => 'TKT-003' )->{linkage}{links}[0]{type},
    'is-blocked-by', 'the reciprocal link landed on the target' );

$error = eval { $calls->[0]{link_add}->( { from => 'TKT-001', type => 'nonsense', to => 'TKT-003' } ); 1 } ? '' : $@;
like( $error, qr/Unknown link type/, 'unknown link types are refused by the engine' );

my $removed = decode_json( $calls->[0]{link_remove}->( { from => 'TKT-001', type => 'blocks', to => 'TKT-003' } ) );
ok( $removed->{ok}, 'typed link removal succeeds through the provider' );
is( scalar @{ $tira->record_show( project => $root, ref => 'TKT-003' )->{linkage}{links} },
    0, 'the reciprocal link is removed too' );

for my $provider (qw(hierarchy_link hierarchy_unlink subitem_link subitem_unlink)) {
    $error = eval { $calls->[0]{$provider}->( { parent => 'TKT-001' } ); 1 } ? '' : $@;
    like( $error, qr/requires/i, "$provider payloads need parent and child" );
}
$error = eval { $calls->[0]{link_add}->( { from => 'TKT-001', type => 'blocks' } ); 1 } ? '' : $@;
like( $error, qr/requires/i, 'link add payloads need from, type, and to' );

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
    checklist_add => sub { '{"ok":true}' }, checklist_update => sub { '{"ok":true}' },
    required_action_update => sub { '{"ok":true}' },
    link_types => sub { '[{"outward":"blocks","inward":"is-blocked-by"}]' },
    police_log => sub { '[]' },
    policies => sub { '{"declared":[],"declined":[],"undeclared":[],"rules":{},"actions":[]}' },
    policy_add => sub { '{"ok":true}' },
    policy_remove => sub { '{"ok":true}' },
    policy_decline => sub { '{"ok":true}' },
    tasklist => sub { '[]' },
    tasklist_add => sub { '{}' },
    tasklist_update => sub { '{}' },
    tasklist_next => sub { '{}' },
    tasklist_shift => sub { '{}' },
    tasklist_pop => sub { '{}' },
    tasklist_unshift => sub { '{}' },
    tasklist_slice => sub { '{}' },
    tasklist_remove => sub { '{}' },
    tasklist_import => sub { '{}' },
    tasklist_prune => sub { '{}' },
    tasklist_task_attach_add => sub { '{}' },
    tasklist_task_attach_discard => sub { '{}' },
    tasklist_task_ref_link => sub { '{}' },
    tasklist_task_ref_unlink => sub { '{}' },
    tasklist_sessions => sub { '[]' },
    hierarchy_link => sub { '{"ok":true}' }, hierarchy_unlink => sub { '{"ok":true}' },
    subitem_link => sub { '{"ok":true}' }, subitem_unlink => sub { '{"ok":true}' },
    link_add => sub { '{"ok":true}' },
    link_remove => sub { die "Unknown link type 'nope'\n" },
);

for my $missing (qw(link_types hierarchy_link hierarchy_unlink subitem_link subitem_unlink link_add link_remove)) {
    my %incomplete = %providers;
    delete $incomplete{$missing};
    eval { Tira::DashboardWeb->build_psgi_app(%incomplete) };
    ( my $label = $missing ) =~ tr/_/ /;
    like( $@, qr/Missing dashboard \Q$label\E provider/, "PSGI builder requires the $missing provider" );
}

my $app = Tira::DashboardWeb->build_psgi_app(%providers);
test_psgi $app, sub {
    my ($client) = @_;
    my $types_response = $client->( GET '/link-types' );
    is( $types_response->code, 200, 'the link types route responds' );
    is( decode_json( $types_response->content )->[0]{outward}, 'blocks', 'link types are served as JSON' );

    for my $path (qw(/hierarchy/link /hierarchy/unlink /subitem/link /subitem/unlink /link/add)) {
        my $response = $client->(
            POST $path, Content_Type => 'application/json', Content => '{"parent":"A","child":"B","from":"A","type":"blocks","to":"B"}',
        );
        is( $response->code, 200, "the $path route responds" );
    }

    my $failing = $client->(
        POST '/link/remove', Content_Type => 'application/json', Content => '{"from":"A","type":"nope","to":"B"}',
    );
    is( $failing->code, 422, 'a failing link removal is unprocessable' );
    like( decode_json( $failing->content )->{error}, qr/Unknown link type/, 'the failure carries the engine error' );
};

done_testing;

__END__

=head1 NAME

23-dashboard-linkage.t - dialog linkage editing providers and routes

=head1 DESCRIPTION

Guards the linkage provider set (hierarchy, subitem, typed links with
reciprocals, link-type choices), their Dancer2 routes' dispatch and 422
semantics, and the renderer contract for the interactive linkage section,
heading pencils, and the small-screen media query.

=cut
