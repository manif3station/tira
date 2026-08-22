#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Request::Common qw(GET POST);
use Cpanel::JSON::XS ();
use Plack::Test;
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
use Tira::DashboardWeb;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-11T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Attributed', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ATS', epic_prefix => 'ATE', ticket_prefix => 'ATT',
);
$tira->login_register( project => $root, id => 'michael', password => 'hunter2' );

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Something to act on' );

my $app = Tira::DashboardWeb->build_psgi_app(
    Tira::CLI::browser_providers( tira => $tira, project => $root ),
    render => sub { '<!doctype html><p>board</p>' },
    data => sub { '{"ticket":{"backlog":[]}}' },
);

test_psgi $app, sub {
    my ($http) = @_;
    my $login = $http->( POST '/login', Content => '{"id":"michael","password":"hunter2"}' );
    my ($token) = ( $login->header('Set-Cookie') // '' ) =~ /tira_session=([^;]+)/;
    ok( $token, 'signed in, so the board knows who is acting' );
    my $as_michael = "tira_session=$token";

    # --- a comment is authored by whoever is signed in --------------------

    # The whole reason the login was worth building, in his words: once we know
    # who they are, the person is pre-selected when they leave a comment.
    my $commented = $http->( POST '/comment/add', Cookie => $as_michael,
        Content => Cpanel::JSON::XS->new->encode(
            { type => 'ticket', ref => $card->{ref}, text => 'Looks right to me' } ) );
    is( $commented->code, 200, 'a comment can be left from the board' );

    my $with_comment = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    is( $with_comment->{comments}[0]{author}, 'michael',
        'and it is authored by the signed-in person, without them choosing' );

    # A comment is personal, unlike an assignment or a move - TKT-458, his own
    # words: "if I make a mistake and pick someone else, it becomes their
    # comment - that's not acceptable." So unlike every other mutation here,
    # an explicit author does NOT win for a comment: the signed-in session is
    # not a default, it is the only choice, because the board's own comment
    # composer no longer offers one.
    $http->( POST '/comment/add', Cookie => $as_michael,
        Content => Cpanel::JSON::XS->new->encode(
            { type => 'ticket', ref => $card->{ref}, author => 'claude',
              text => 'Recording this for Michael' } ) );
    my $both = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    is( $both->{comments}[1]{author}, 'michael',
        'a comment cannot be misattributed by an author sent from the board - the session always wins' );

    # --- a card created from the board is reported by them ----------------

    my $created = $http->( POST '/create', Cookie => $as_michael,
        Content => Cpanel::JSON::XS->new->encode(
            { type => 'ticket', column => 'backlog', title => 'Raised from the board' } ) );
    is( $created->code, 200, 'a card can be created from the board' );
    my $new_ref = Cpanel::JSON::XS->new->decode( $created->content )->{record}{ref};
    is( $tira->record_show( project => $root, type => 'ticket', ref => $new_ref )->{reporter},
        'michael', 'and the signed-in person is its reporter by default' );

    # --- moving a card says who moved it ----------------------------------

    # The board recorded what happened and never who did it. That was not a
    # design choice - there was nobody to name until somebody could sign in.
    $http->( POST '/move', Cookie => $as_michael,
        Content => Cpanel::JSON::XS->new->encode(
            { type => 'ticket', ref => $card->{ref}, column => 'implement' } ) );
    my @moves = grep { ( $_->{field} // '' ) eq 'column' }
      @{ $tira->history_list( project => $root, ref => $card->{ref} ) };
    ok( scalar @moves, 'the move is in the history' );
    is( $moves[-1]{author}, 'michael', 'and the history says who moved it' );
};

# --- the command line is untouched ---------------------------------------

# A command line caller has no session to read, so nothing about it changes.
# Attribution is something the browser can do because somebody signed in, not
# a new obligation on everybody.
my $from_cli = $tira->comment_add( project => $root, ref => $card->{ref},
    author => 'claude', text => 'From a terminal' );
is( $from_cli->{author}, 'claude', 'a comment from the command line is authored as asked' );

my $anonymous = $tira->create_record( project => $root, type => 'ticket', title => 'From a script' );
is( $anonymous->{reporter}, undef,
    'and a card created with no reporter still has none, rather than being given one' );

done_testing;

__END__

=head1 NAME

90-attribution.t - the board can finally say who did something

=head1 DESCRIPTION

The owner's reason for wanting a login, which is better than the security one:
once the board knows who is there, it can record who acted. Before this it kept
what happened and never who did it - not a design choice, but the consequence
of there being nobody to name.

So a comment left from the board is authored by whoever is signed in, a card
they create names them as its reporter, and moving a card writes them into the
history. An explicit author still wins, because an agent acting on somebody's
behalf is a real case and the session is a default rather than a straitjacket.

Nothing on the command line changes. A caller there has no session to read, and
attribution is something the browser gained by somebody signing in rather than
a new obligation on everybody.

=cut
