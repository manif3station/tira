#!/usr/bin/env perl
# TKT-966, his TG 7230. An unmatched route logged a raw Template::Exception
# dump for a missing 404.tt - Dancer2's own default error rendering, since
# this app has never had a view for error pages (Perl string concatenation
# does its own rendering). Four identical lines in 48 seconds pointed at
# something polling a path this board never served, and the trace named
# neither the endpoint asked for nor who was asking.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Request::Common qw(GET);
use Plack::Test;
use Test::More;

use lib 'lib', 't/lib';
use GatedApp qw(signed_in);
use Tira;
use Tira::DashboardWeb;

my $renders = 0;
my $app = Tira::DashboardWeb->build_psgi_app(
    signed_in(),
    render => sub { $renders++; return '<!doctype html><p>Live</p>' },
    data => sub { return '{}' },
    move => sub { return '{"ok":true}' },
    detail => sub { return '{}' },
    search => sub { '[]' },
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
    jobs              => sub { '[]' },
    job_run           => sub { '{}' },
    job_check         => sub { '{"ok":true}' },
    job_save          => sub { '{}' },
    job_delete        => sub { '{}' },
    job_stop          => sub { '{}' },
    job_start         => sub { '{}' },
    columns => sub { '[]' },
    question_answer => sub { '{"ok":true}' },
    question_mark => sub { '{"ok":true}' },
    question_attach => sub { '{"ok":true}' },
    column_apply => sub { '{}' },
    create => sub { '{"ok":true,"record":{"ref":"TKT-009"}}' },
    update => sub { return '{"ok":true}' },
    comment_add => sub { return '{"ok":true}' },
    comment_update => sub { return '{"ok":true}' },
    comment_remove => sub { return '{"ok":true}' },
    people => sub { return '[]' },
    attachment_fetch => sub { return { content => '', content_type => 'text/plain; charset=UTF-8', filename => 'x.txt', inline => 1 } },
    attachment_add => sub { return '{"ok":true}' },
    attachment_remove => sub { return '{"ok":true}' },
    attachment_discard => sub { '{"ok":true}' },
    checklist_add => sub { return '{"ok":true}' },
    checklist_update => sub { return '{"ok":true}' },
    required_action_update => sub { return '{"ok":true}' },
    gate_add => sub { '{}' },
    gate_annotate => sub { '{}' },
    evidence_add => sub { '{}' },
    evidence_annotate => sub { '{}' },
    release_record => sub { '{}' },
    link_types => sub { '[]' },
    hierarchy_link => sub { '{"ok":true}' },
    hierarchy_unlink => sub { '{"ok":true}' },
    subitem_link => sub { '{"ok":true}' },
    subitem_unlink => sub { '{"ok":true}' },
    link_add => sub { '{"ok":true}' },
    link_remove => sub { '{"ok":true}' },
);

# --- helper: run a block with STDERR captured to a string, cleanly ---------

sub with_captured_stderr {
    my ($code) = @_;
    local *STDERR;
    my $captured = '';
    open STDERR, '>', \$captured or die $!;
    $code->();
    close STDERR;
    return $captured;
}

# --- an unmatched route answers 404 with no Template::Exception ------------

my $captured = with_captured_stderr( sub {
    test_psgi $app, sub {
        my ($client) = @_;
        my $response = $client->(
            GET '/does-not-exist?x=1', Referer => 'http://elsewhere.example/page' );
        is( $response->code, 404, 'an unmatched route answers 404' );
    };
} );
unlike( $captured, qr/Template::Exception/, 'no Template::Exception dump appears' );
like( $captured, qr{\Q/does-not-exist?x=1\E}, 'the log names the full path, including the query' );
like( $captured, qr/GET/, 'and the method' );
like( $captured, qr/elsewhere\.example/, 'and the referer, when one was sent' );
unlike( $captured, qr/Wide character/, 'no implicit wide-character warning leaked' );

# --- two different missing endpoints produce two distinguishable lines -----

$captured = with_captured_stderr( sub {
    test_psgi $app, sub {
        my ($client) = @_;
        $client->( GET '/first-missing' );
        $client->( GET '/second-missing' );
    };
} );
like( $captured, qr{\Q/first-missing\E}, 'the first missing path is named' );
like( $captured, qr{\Q/second-missing\E}, 'and the second, distinctly' );
my @lines = grep { /missing/ } split /\n/, $captured;
my %unique = map { $_ => 1 } @lines;
is( scalar keys %unique, 2, 'the two requests produced two DIFFERENT lines, not one repeated' );

# --- the two deliberate 404s are unchanged ----------------------------------

{
    my ( $logs_response );
    with_captured_stderr( sub {
        test_psgi $app, sub {
            my ($client) = @_;
            $logs_response = $client->( GET '/logs' );
        };
    } );
    is( $logs_response->code, 404, '/logs without --show-logs still answers 404' );
    like( $logs_response->content, qr/not started with --show-logs/,
        'with its own explanatory body, unchanged' );
}

done_testing();

__END__

=head1 NAME

599-a-404-that-said-nothing-useful.t - an unmatched route logs what asked for it

=head1 DESCRIPTION

TKT-966, his TG 7230. C<Tira::DashboardWeb> had no catch-all route, so an
unmatched request fell through to Dancer2's own default error rendering -
which this app was never given a template for, since every page here comes
from Perl string concatenation rather than a template engine. The result was
a raw C<Template::Exception> dump on the terminal, naming neither the
endpoint requested nor the caller.

A catch-all route now answers such a request with a plain 404 and logs one
line naming the method, the full path (including query), the referer when
one was sent, and the client address - the "which endpoint" and "what was
calling it" his report asked for. The two deliberate 404s this app already
returns - C</logs> without C<--show-logs>, and an unknown attachment -
answer exactly as before.

=cut
