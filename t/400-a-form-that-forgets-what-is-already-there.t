#!/usr/bin/env perl
# TKT-543: the CLI wizard pre-fills every field from an existing project at
# the chosen directory (_wizard_defaults); the browser onboarding form has
# no equivalent and always starts blank/hardcoded, forcing a person editing
# an existing project to guess its current name/members/columns correctly.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Request::Common qw(GET);
use Test::More;
use Plack::Test;

use lib 'lib';
use Tira;
use Tira::CLI;
use Tira::OnboardWeb;
# Tira::CLI::Wizard holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Wizard;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'zen' );
my $tira = Tira->new;
$tira->project_new(
    dir => $root, name => 'Zen', members => 'ada, bob', sow_prefix => 'ZNS',
    epic_prefix => 'ZNE', ticket_prefix => 'ZNT', columns => 'todo, doing, done',
);

my $app = Tira::OnboardWeb->build_psgi_app(
    create   => sub { die "not used in this test\n" },
    dir      => $root,
    defaults => sub { Tira::CLI::Wizard::_wizard_defaults( $tira, $_[0] ) },
);

test_psgi $app, sub {
    my ($http) = @_;

    my $form = $http->( GET '/' );
    is( $form->code, 200, 'the front page still answers' );
    like( $form->content, qr/value="\Q$root\E"/, 'pre-fills the directory it was pointed at' );
    like( $form->content, qr/value="Zen"/, 'pre-fills the existing project name' );
    like( $form->content, qr/value="ada, bob"/, 'pre-fills the existing members' );
    like( $form->content, qr/value="ZNS"/, 'pre-fills the existing sow prefix' );
    like( $form->content, qr/value="ZNE"/, 'pre-fills the existing epic prefix' );
    like( $form->content, qr/value="ZNT"/, 'pre-fills the existing ticket prefix' );
    like( $form->content, qr/value="[^"]*todo, doing, done[^"]*"/, 'pre-fills the existing columns' );
};

$tira->person_add( project => $root, id => 'claude', name => 'Claude' );
$tira->project_update(
    project => $root, notify_after => 45, agent => 'claude', session => 'zen-session',
    collector => 'zen-reminders',
);
$tira->project_mode( project => $root, mode => 'chain' );

my $app_full = Tira::OnboardWeb->build_psgi_app(
    create   => sub { die "not used in this test\n" },
    dir      => $root,
    defaults => sub { Tira::CLI::Wizard::_wizard_defaults( $tira, $_[0] ) },
    questions => $tira->onboarding_questions,
);
test_psgi $app_full, sub {
    my ($http) = @_;

    # TKT-559: name/members/prefixes/columns already pre-fill (TKT-543) -
    # notify_after/agent/session/collector/mode never did, despite
    # _wizard_defaults already returning all five.
    my $form = $http->( GET '/' );
    like( $form->content, qr/name="notify_after" value="45"/, 'pre-fills the existing stuck-minutes setting' );
    like( $form->content, qr/name="agent" value="claude"/, 'pre-fills the existing agent' );
    like( $form->content, qr/name="session" value="zen-session"/, 'pre-fills the existing session' );
    like( $form->content, qr/name="collector" value="zen-reminders"/, 'pre-fills the existing collector' );
    like( $form->content, qr/name="mode" value="chain"/, 'pre-fills the existing onboarding question answer (mode)' );
};

my $app_no_defaults = Tira::OnboardWeb->build_psgi_app(
    create => sub { die "not used in this test\n" }, dir => $root,
);
test_psgi $app_no_defaults, sub {
    my ($http) = @_;
    my $form = $http->( GET '/' );
    is( $form->code, 200, 'a dir with no defaults provider still answers' );
    like( $form->content, qr/value="\Q$root\E"/, 'and still shows the given directory' );
    like( $form->content, qr/name="name" value=""/, 'with no defaults to pre-fill the rest' );
};

done_testing;

__END__

=head1 NAME

400-a-form-that-forgets-what-is-already-there.t - the browser onboarding form pre-fills from an existing project

=head1 DESCRIPTION

TKT-543: given an existing Tira project at a directory, C<GET /> on the
disposable onboarding form pre-fills name/members/columns/prefixes from
that project's actual stored values, the same way the CLI wizard's
C<_wizard_defaults> already does - rather than always starting blank except
for hardcoded SOW/EPC/TKT prefix defaults.

=cut
