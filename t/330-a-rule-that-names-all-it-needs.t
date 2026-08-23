#!/usr/bin/env perl
# policy_add refused a rule's missing options one at a time - declaring
# card-metrics (needs --enter and --require) bare cost three attempts for
# two options: --rule alone refused for --enter, adding --enter refused for
# --require, and only the third succeeded. Each refusal named exactly the
# option it wanted, which is not the gap - the gap is that a caller had no
# way to ask what a rule needs before trying, and a refusal that only ever
# names the FIRST missing option cannot answer that either, one round trip
# short every time. tira.policies already lists every rule's needs in full;
# the refusal did not point there. TKT-289.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Policies', dir => $root, members => ['claude'],
    sow_prefix => 'PLS', epic_prefix => 'PLE', ticket_prefix => 'PLT',
);

# --- both missing options are named in one refusal, not one at a time ------

{
    my $error = eval {
        $tira->policy_add( project => $root, rule => 'card-metrics', action => 'log-only' );
        1;
    } ? undef : $@;
    like( $error, qr/--enter/,   'names the first missing option' );
    like( $error, qr/--require/, 'and the second, in the same refusal' );
    like( $error, qr/tira\.policies/, 'and points at the command that lists every rule\'s needs' );
}

# --- supplying one still names the other, not both again -------------------

{
    my $error = eval {
        $tira->policy_add( project => $root, rule => 'card-metrics', action => 'log-only', enter => 'implement' );
        1;
    } ? undef : $@;
    unlike( $error, qr/--enter\b/, 'the option already given is not named as missing' );
    like( $error, qr/--require/, 'only the one still missing is' );
}

# --- a rule needing just one option is refused the same way, still pointing at tira.policies --

{
    my $error = eval {
        $tira->policy_add( project => $root, rule => 'card-full-details', action => 'log-only' );
        1;
    } ? undef : $@;
    like( $error, qr/--enter/,        'a single-need rule still names what it needs' );
    unlike( $error, qr/\band\b/,      'and does not talk about a second option that does not exist' );
}

# --- and a fully-declared rule succeeds, unaffected -------------------------

{
    my $policy = $tira->policy_add(
        project => $root, rule => 'card-metrics', action => 'log-only',
        enter => 'implement', require => 'start_date',
    );
    is( $policy->{rule}, 'card-metrics', 'declaring both options together still succeeds' );
}

done_testing;

__END__

=head1 NAME

330-a-rule-that-names-all-it-needs.t - policy_add names every missing option in one refusal

=head1 DESCRIPTION

C<policy_add> refused a rule's missing required options one at a time -
the first C<die> in the loop fired on the first missing option, so a rule
needing two took two separate attempts (three round trips total: bare,
one option, both) to discover fully. It now collects every missing option
and refuses once, naming all of them and pointing at C<tira.policies>
for the complete list. TKT-289.

=cut
