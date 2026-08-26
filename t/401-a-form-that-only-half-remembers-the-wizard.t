#!/usr/bin/env perl
# TKT-553: the CLI wizard (_project_wizard in lib/Tira/CLI.pm) asks for
# notify_after (stuck-card minutes), agent/session/collector, and every
# onboarding_questions() entry (e.g. project mode) - none of which the
# browser onboarding form offers at all, despite its own POD claiming full
# field parity with the CLI wizard.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Request::Common qw(GET POST);
use Test::More;
use Plack::Test;

use lib 'lib';
use Tira;
use Tira::OnboardWeb;

my $tira_for_questions = Tira->new;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'zen' );

my @created;
my $app = Tira::OnboardWeb->build_psgi_app(
    create => sub {
        my ($answers) = @_;
        push @created, $answers;
        return { project => { name => $answers->{name} } };
    },
    questions => $tira_for_questions->onboarding_questions,
);

test_psgi $app, sub {
    my ($http) = @_;

    my $form = $http->( GET '/' );
    like( $form->content, qr/name="notify_after"/, 'offers a stuck-minutes field' );
    like( $form->content, qr/name="agent"/,        'offers an agent field' );
    like( $form->content, qr/name="session"/,       'offers a session field' );
    like( $form->content, qr/name="collector"/,      'offers a collector field' );
    like( $form->content, qr/name="mode"/, 'offers a field for the mode onboarding question' );
    like( $form->content, qr/single or chain/i, 'naming its options, like the CLI wizard names them' );

    my $ok = $http->( POST '/',
        [ name => 'Zen', dir => $root, notify_after => '30', agent => 'claude',
          session => 'zen-session', collector => 'zen-reminders', mode => 'chain' ] );
    is( $ok->code, 200, 'a submission with the new fields succeeds' );
    is( $created[0]{notify_after}, '30', 'and reaches the create provider' );
    is( $created[0]{agent}, 'claude', 'with the agent' );
    is( $created[0]{session}, 'zen-session', 'the session' );
    is( $created[0]{collector}, 'zen-reminders', 'the collector' );
    is( $created[0]{mode}, 'chain', 'and the onboarding question answer' );
};

done_testing;

__END__

=head1 NAME

401-a-form-that-only-half-remembers-the-wizard.t - the browser onboarding form offers every field the CLI wizard does

=head1 DESCRIPTION

TKT-553: C<GET /> on the disposable onboarding form now offers
C<notify_after>/C<agent>/C<session>/C<collector> and one field per
C<Tira-E<gt>onboarding_questions()> entry (naming its options), and a
submission including them reaches the C<create> provider with the same
keys the CLI wizard's own answers hash would carry.

=cut
