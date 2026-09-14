#!/usr/bin/env perl
# TKT-667. Found by the hourly bug hunt reading lib/Tira/OnboardWeb.pm
# against the CLI wizard it mirrors (TKT-543/t/400's own precedent).
#
# _wizard_defaults (lib/Tira/CLI/Wizard.pm) only sets the shared 'columns'
# key when every board type (sow/epic/ticket) has IDENTICAL columns; when
# they differ it sets only the per-type sow_columns/epic_columns/
# ticket_columns keys instead, leaving 'columns' undefined. But
# _fields_from_defaults (lib/Tira/OnboardWeb.pm) only ever reads the shared
# 'columns' key - never the per-type ones - so a project whose boards have
# diverged shows an EMPTY Columns box on the browser onboarding form, which
# reads as though the project has no columns at all, rather than showing
# what it actually has.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Request::Common qw(GET);
use Test::More;
use Plack::Test;

use lib 'lib';
use Tira;
use Tira::OnboardWeb;
require Tira::CLI::Wizard;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'zen' );
my $tira = Tira->new;
$tira->project_new(
    dir => $root, name => 'Zen',
    sow_columns    => 'planning, active, shipped',
    epic_columns   => 'backlog, doing, done',
    ticket_columns => 'backlog, doing, done',
);

my $app = Tira::OnboardWeb->build_psgi_app(
    create   => sub { die "not used in this test\n" },
    dir      => $root,
    defaults => sub { Tira::CLI::Wizard::_wizard_defaults( $tira, $_[0] ) },
);

test_psgi $app, sub {
    my ($http) = @_;

    my $form = $http->( GET '/' );
    is( $form->code, 200, 'the front page still answers for a project with divergent board columns' );
    like( $form->content, qr/value="Zen"/, 'still pre-fills the project name' );
    like( $form->content, qr/onboard-note/,
        'a note explains the boards have diverged, rather than leaving the reader to guess why the box is empty' );
    like( $form->content, qr/planning, active, shipped/,
        'the sow board columns appear on the form somewhere' );
    like( $form->content, qr/doing, done/,
        'the epic/ticket board columns appear on the form somewhere' );
};

# --- one board type's own data missing is treated as unsafe too ------------
#
# Codex review: _wizard_defaults sets the shared 'columns' key from
# whichever types its own eval actually reached agreeing with each other -
# not from all three unconditionally. A project where one type's column
# data could not be read at all (a legacy or corrupted board file, however
# rare) would have only two types agreeing, which _wizard_defaults' own
# check reads as "shared" - trusting that key alone would pre-fill the box
# and risk a silent submit overwriting the third, unread type to match.
# Simulated directly (rather than trying to corrupt a real board file) by
# calling _fields_from_defaults with exactly that shape: two types
# present and equal, the third missing entirely.

{
    my $fields = Tira::OnboardWeb::_fields_from_defaults( {
        name          => 'Zen',
        epic_columns  => ['backlog, doing, done'],
        ticket_columns => ['backlog, doing, done'],
        # sow_columns deliberately absent - the "could not be read" case.
    } );
    is( $fields->{columns}, undef,
        "two types agreeing is not enough to pre-fill the shared box when the third type's own data is simply missing" );
    like( $fields->{columns_note}, qr/epic: backlog, doing, done/,
        'the note still shows what IS known' );
    unlike( $fields->{columns_note}, qr/sow:/,
        'and says nothing for the type with no data at all, rather than inventing one' );
}

done_testing;

__END__

=head1 NAME

1090-a-box-that-forgot-three-answers.t - the onboarding form shows a project's real columns even when its boards diverge

=head1 DESCRIPTION

TKT-667. C<_wizard_defaults> only fills the shared C<columns> default when
every board type has identical columns; a project whose boards have
diverged has none of that key, only per-type C<sow_columns>/
C<epic_columns>/C<ticket_columns>. C<_fields_from_defaults> only ever read
the shared key, so the browser onboarding form's Columns box came back
empty for exactly the projects most likely to need it shown accurately.

=cut
