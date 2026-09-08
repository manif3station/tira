#!/usr/bin/env perl
# TKT-688. _render_form escapes a question's text (line 69) but joins its
# options in raw and interpolates its id into a double-quoted attribute
# with no escaping at all (lines 69-71). Nothing user-supplied reaches
# these lines today - onboarding_questions() is hardcoded - but
# build_psgi_app takes questions as a parameter and stores whatever
# array it is handed, so the contract already admits a caller supplying
# them.
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

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'zen' );

my $hostile = {
    id      => 'nasty"><script>alert(1)</script>',
    text    => "Which way'd should this go?",
    options => [ '<b>bold</b>', "it's fine" ],
};

my $app = Tira::OnboardWeb->build_psgi_app(
    create    => sub { die "not used in this test\n" },
    dir       => $root,
    questions => [$hostile],
);

test_psgi $app, sub {
    my ($http) = @_;
    my $form = $http->( GET '/' );
    is( $form->code, 200, 'the front page still answers' );

    unlike( $form->content, qr/<b>bold<\/b>/,
        "a question's options render as text, not as markup" );
    unlike( $form->content, qr/<script>alert\(1\)<\/script>/,
        "an option's script tag does not survive into the body unescaped" );

    unlike( $form->content, qr/name="nasty"><script>/,
        "a double quote in a question's id cannot break out of the name attribute" );
    like( $form->content, qr/name="nasty&quot;&gt;&lt;script&gt;/,
        "the id is fully escaped inside the attribute" );
};

# --- _escape itself: the single quote was the one character it dropped ------

is( Tira::OnboardWeb::_escape(q{it's & <fine> "quoted"}),
    'it&#39;s &amp; &lt;fine&gt; &quot;quoted&quot;',
    '_escape converts all five characters: & < > " and the single quote' );

# --- the hardcoded mode question is unaffected -------------------------------

my $app_default = Tira::OnboardWeb->build_psgi_app(
    create    => sub { die "not used in this test\n" },
    dir       => $root,
    questions => Tira->onboarding_questions,
);

test_psgi $app_default, sub {
    my ($http) = @_;
    my $form = $http->( GET '/' );
    like( $form->content, qr/Is this project worked by a single agent, or by a chain of agents\?/,
        'the real hardcoded mode question still renders as before' );
};

done_testing();

__END__

=head1 NAME

688-a-label-that-forgot-to-escape.t - the onboarding form escapes a
question's text but not its options or its id

=head1 DESCRIPTION

TKT-688. C<_render_form> interpolates a question's C<text>, C<options>
and C<id> across three consecutive lines and only escaped C<text>. Fixed
by routing all three through C<_escape>, and by giving C<_escape> the
single quote it previously passed through unchanged.

=cut
