#!/usr/bin/env perl
# TKT-517: the disposable onboarding page itself - one form, one submission,
# then a 503 for anything after. Tested at the PSGI level with Plack::Test,
# the same shape t/378 and t/391 already use for other dashboard providers -
# no real socket needed to exercise the form/validate/create/stop contract.

use strict;
use warnings;

use HTTP::Request::Common qw(GET POST);
use Test::More;
use Plack::Test;

use lib 'lib';
use Tira::OnboardWeb;

eval { Tira::OnboardWeb->build_psgi_app() };
like( $@, qr/needs a create provider/i, 'building without a create provider refuses' );

my @created;
my $app = Tira::OnboardWeb->build_psgi_app(
    create => sub {
        my ($answers) = @_;
        die "A project needs a name.\n" if !defined $answers->{name} || $answers->{name} eq '';
        push @created, $answers;
        return { project => { name => $answers->{name} } };
    },
);

test_psgi $app, sub {
    my ($http) = @_;

    my $form = $http->( GET '/' );
    is( $form->code, 200, 'the front page answers' );
    like( $form->content, qr/Project name/i, 'and offers the name field' );
    like( $form->content, qr/Project directory/i, 'and the directory field' );
    like( $form->content, qr/SOW reference prefix/i, 'and the prefix fields' );

    my $invalid = $http->( POST '/', [ name => '', dir => '/tmp/whatever' ] );
    is( $invalid->code, 422, 'an empty name is refused' );
    like( $invalid->content, qr/needs a name/i, 'naming why' );
    like( $invalid->content, qr/value="\/tmp\/whatever"/, 'and keeps what was already typed' );
    is( scalar @created, 0, 'and nothing was created' );

    my $ok = $http->(
        POST '/', [ name => 'Zen', dir => '/tmp/zen', members => 'ada, bob', sow_prefix => 'ZNS' ] );
    is( $ok->code, 200, 'a valid submission succeeds' );
    like( $ok->content, qr/Thank you for using Tira/i, 'with the thank-you page' );
    like( $ok->content, qr/tira\.dashboard -o browser/, 'reminding the browser command' );
    is( scalar @created, 1, 'and the create provider ran exactly once' );
    is( $created[0]{name}, 'Zen', 'with the typed name' );
    is( $created[0]{dir}, '/tmp/zen', 'and the typed directory' );
    is_deeply( $created[0]{members}, ['ada, bob'], 'and the typed people' );
    is( $created[0]{sow_prefix}, 'ZNS', 'and an overridden prefix' );

    my $after = $http->( GET '/' );
    is( $after->code, 503, 'a further request after success gets refused' );
    my $after_post = $http->( POST '/', [ name => 'Another' ] );
    is( $after_post->code, 503, 'a further submission gets refused too' );
    is( scalar @created, 1, 'and does not create a second project' );
};

done_testing;

__END__

=head1 NAME

392-a-place-to-answer-before-the-board-exists.t - Tira::OnboardWeb's form/validate/create/stop contract

=head1 DESCRIPTION

TKT-517: the disposable onboarding page tested at the PSGI level with
Plack::Test - a missing create provider is refused, GET / offers the form,
an invalid submission re-renders it with the typed values and the reason,
a valid submission creates exactly once and answers a thank-you page, and
anything after that gets a 503 rather than a second form.

=cut
