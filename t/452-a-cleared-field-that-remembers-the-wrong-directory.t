#!/usr/bin/env perl
# TKT-776. GET / falls back to $INITIAL_DIR (the real directory the
# onboarding session was launched for, set in build_psgi_app) when the
# 'dir' form param is missing or empty:
#
#   my $dir = scalar(params->{dir}) || $INITIAL_DIR;
#
# POST / does NOT consult $INITIAL_DIR at all - _answers_from_params
# computes dir purely from submitted form fields, defaulting to the
# LITERAL STRING '.' when empty:
#
#   $answers{dir} = ($fields{dir} ne '' ? $fields{dir} : '.')
#
# Nothing marks the 'dir' field as required, so a person can clear it
# (accidentally, or trying to reset a pre-filled value) and submit
# successfully. '.' resolves to whatever directory the onboarding web
# SERVER PROCESS happens to be running from at request time, which has no
# necessary relationship to the project the session was meant to set up -
# a project could be silently created in the wrong place.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Request::Common qw(POST);
use Test::More;
use Plack::Test;

use lib 'lib';
use Tira::OnboardWeb;

my $tmp     = tempdir( CLEANUP => 1 );
my $intended = File::Spec->catdir( $tmp, 'intended-project' );

my @created;
my $app = Tira::OnboardWeb->build_psgi_app(
    create => sub {
        my ($answers) = @_;
        push @created, $answers;
        return { project => { name => $answers->{name} } };
    },
    dir => $intended,
);

test_psgi $app, sub {
    my ($http) = @_;

    my $ok = $http->( POST '/', [ name => 'ClearedDir', dir => '' ] );
    is( $ok->code, 200, 'the submission succeeds despite the cleared dir field' );
    is( $created[0]{dir}, $intended,
        'a cleared dir field falls back to the session\'s own intended directory, not the server\'s cwd - '
          . "got '$created[0]{dir}', expected the intended dir the session was launched for" );
};

# --- control: a session with no directory of its own either refuses, ------
# rather than reaching the create provider with an unusable dir.

my @created_none;
my $app_none = Tira::OnboardWeb->build_psgi_app(
    create => sub {
        my ($answers) = @_;
        push @created_none, $answers;
        return { project => { name => $answers->{name} } };
    },
);

test_psgi $app_none, sub {
    my ($http) = @_;

    my $refused = $http->( POST '/', [ name => 'NoDirAnywhere', dir => '' ] );
    is( $refused->code, 422, 'a cleared field with no session directory to fall back to is refused' );
    like( $refused->content, qr/No project directory to use/,
        'naming why - the field is empty and this session has none of its own' );
    is( scalar @created_none, 0, 'and the create provider never ran' );
};

done_testing;

__END__

=head1 NAME

t/452-a-cleared-field-that-remembers-the-wrong-directory.t - a cleared
onboarding dir field falls back to the session's own directory

=head1 DESCRIPTION

C<_answers_from_params> defaulted an empty submitted C<dir> to the
literal string C<'.'>, which resolves to whatever directory the
onboarding web server process happens to be running from - unrelated to
the project the session was launched for. C<GET /> already had the right
fallback (C<$INITIAL_DIR>); C<POST /> never consulted it. Fixed by having
C<POST /> fall back to C<$INITIAL_DIR> the same way C<GET /> does, so a
cleared field resolves to the session's own intended directory rather
than the server's cwd. TKT-776.

=cut
