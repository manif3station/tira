#!/usr/bin/env perl
# The colour that says whose move it is, on the page that is actually served.
#
# Reported by the owner with a recording of a board on his phone: three cards
# carry questions nobody has answered and none of them is marked. Reproduced on
# a board built for it and served - the card comes back as class="card", and
# every card--waiting in the page is stylesheet.
#
# Both ends were right. The engine says waiting=1 for that card, and rendering
# the same structure directly gives class="card card--waiting". What was wrong
# was in between: the workers build their own providers in dashboard.psgi, and
# they ask dashboard() for summary, include_mtime and with_title - not for
# questions. The CLI defaults with_questions on whenever the output is a board
# somebody is looking at, and says why in a comment beside it, but the CLI is
# not what answers a request. The workers are.
#
# In summary mode a card is only asked whether it is waiting when with_title or
# with_questions is set, so on a board showing refs only - which is how it is
# usually run - the flag is absent and nothing can be yellow at all.
#
# Asserted through the application a worker loads, because that is the thing
# that serves pages. A test that called the CLI's providers would have passed
# all evening.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

my $tira = Tira->new( clock => sub {'2026-08-16T00:00:00Z'} );
$tira->project_new(
    name => 'Waiting', dir => $root, members => [ 'claude', 'michael' ],
    columns => ['backlog, done'],
);

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Waiting on an answer' );

# And one set aside, because the same pair of providers lost this too and for
# the same reason. Every board is created with Backlog and Discard, the owner
# saw one and never the other, and the change answering that went into the CLI
# while the workers - which answer every request - kept their own arguments.
# TKT-247.
my $aside = $tira->create_record( project => $root, type => 'ticket',
    title => 'Set aside' );
$tira->comment_add( project => $root, ref => $aside->{ref}, author => 'claude',
    text => 'not real work' );
$tira->record_discard(author => 'claude',  project => $root, ref => $aside->{ref} );
$tira->question_add(
    project => $root, ref => $card->{ref}, author => 'claude',
    text => 'Which way?', reason => 'It matters',
    options => [ 'This way', 'That way' ],
);

# The engine's own answer, first. If this were wrong the rest would be about
# something else entirely, and the fault reported was never here.
{
    my $board = $tira->dashboard(
        project => $root, summary => 1, with_questions => 1, include_mtime => 1 );
    my ($seen) = grep { $_->{ref} eq $card->{ref} }
      map { @{ $board->{ticket}{$_} } } keys %{ $board->{ticket} };
    ok( $seen->{waiting}, 'the engine knows the card is waiting on an answer' );
}

# --- and what a worker serves ------------------------------------------------
#
# Titles off, which is how a board is usually run and the case the fault hid in.

{
    local $ENV{TIRA_DASHBOARD_ROOT}  = $root;
    local $ENV{TIRA_DASHBOARD_TYPE}  = '';
    local $ENV{TIRA_DASHBOARD_TITLE} = '0';

    # The worker's own providers, caught where it hands them over. Building
    # providers here instead would test this file rather than the one that
    # serves pages, and the CLI's providers were correct all evening - that is
    # exactly why nothing caught this.
    require Tira::DashboardWeb;
    my %given;
    my $app;
    {
        no warnings 'redefine';
        local *Tira::DashboardWeb::build_psgi_app = sub { shift; %given = @_; return sub {1} };
        $app = do './dashboard.psgi';
    }

    ok( ref $app eq 'CODE', 'the application a worker loads is something a server can run' )
      or diag( $@ || $! );
    ok( ref $given{render} eq 'CODE', 'and it hands the server something to render with' );

    my $page = $given{render}->();

    # non-empty is the whole claim: a precondition for the two assertions
    # below, which would otherwise pass against a page that failed to render.
    like( $page, qr/\S/, 'and it renders a page' );
    like( $page, qr/\Q$card->{ref}\E/, 'with the card on it' );
    like( $page, qr/class="card card--waiting"/,
        'marked as waiting on an answer, with titles off, which is how a board is usually run' );
    like( $page, qr/\Q$aside->{ref}\E/,
        'and the card somebody set aside is on the page, so a person can see where discarded work went' );
}

done_testing;

__END__

=head1 NAME

218-a-card-waiting-on-an-answer.t - the colour that says whose move it is

=head1 DESCRIPTION

A card whose question nobody has answered is yellow, so the owner can see whose
move it is without opening anything. On a served board it never was: the
workers build their own providers and did not ask C<dashboard()> for questions,
so in summary mode the card was never asked whether it was waiting.

Asserted through the application a worker loads, because that is what answers a
request. The CLI's own providers were correct all along, which is why nothing
caught this.

=cut
