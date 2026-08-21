#!/usr/bin/env perl
# notify_moves writes to the board when asked only to read it.
#
# MEASURED while diagnosing why move notifications never reach the owner:
# tira.project.show showed no notify_moves key, then a bare tira.notify.moves
# (asked only to read the setting) made the key appear - "enabled":true,
# invented by nobody's decision. lib/Tira.pm's engine method does
# `$data->{notify_moves} ||= { enabled => 0, columns => {} }` and then calls
# _write_yaml unconditionally, so a bare read persists the default. Worse,
# the CLI dispatch layer always passes `enabled => (--watch given ? that :
# 1)` to the engine, so even a genuinely bare `d2 tira.notify.moves` looks,
# from the engine's side, exactly like "turn it on" was asked for.
#
# The harm is not the extra write - it is that the first diagnostic question
# ("has anybody turned this on?") destroys the answer by being asked.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Quiet', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'NMS', epic_prefix => 'NME', ticket_prefix => 'NMT',
);

sub cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    return Tira::CLI->run( command => 'notify.moves', argv => \@argv );
}

# --- an engine-level bare read persists nothing --------------------------------

is( $tira->project_show( project => $root )->{notify_moves}, undef,
    'a board that never asked about notifications has no setting' );

my $read = $tira->notify_moves( project => $root );
is( $tira->project_show( project => $root )->{notify_moves}, undef,
    'a bare engine-level read still has no setting - asking did not create one' );
ok( !$read->{enabled}, 'and reports the true default: off' );

# --- a genuine change persists, and reports what it set -----------------------

my $changed = $tira->notify_moves( project => $root, enabled => 1 );
ok( $changed->{enabled}, 'asking to turn it on reports it on' );
ok( $tira->project_show( project => $root )->{notify_moves}{enabled},
    'and this time the board actually remembers it' );

# --- the CLI dispatch layer must not manufacture a change either ---------------
#
# Even with the engine fixed, the CLI unconditionally passed enabled => 1
# whenever --watched was not given, so a bare `d2 tira.notify.moves` looked
# indistinguishable from `d2 tira.notify.moves --watched` from the engine's
# side. A fresh project isolates this from the assertions above.

{
    my $root2 = File::Spec->catdir( $tmp, 'proj2' );
    my $tira2 = Tira->new;
    $tira2->project_new(
        name => 'CLIQuiet', dir => $root2, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'CQS', epic_prefix => 'CQE', ticket_prefix => 'CQT',
    );
    local $ENV{TIRA_HOME} = $root2;

    Tira::CLI->run( command => 'notify.moves', argv => [] );
    is( $tira2->project_show( project => $root2 )->{notify_moves}, undef,
        'a bare CLI notify.moves, with no flags at all, persists no setting' );

    Tira::CLI->run( command => 'notify.moves', argv => [ '--watch' ] );
    ok( $tira2->project_show( project => $root2 )->{notify_moves}{enabled},
        'but an explicit --watch still turns it on and persists that' );
}

done_testing;

__END__

=head1 NAME

316-a-question-that-answered-itself.t - reading the move-notification setting no longer creates it

=head1 DESCRIPTION

C<notify_moves> used C<||=> to invent a default and then wrote it back
unconditionally on every call, so asking "has anybody turned this on?" made
the answer yes. The CLI dispatch compounded it by always passing C<enabled>
(defaulting to 1 when C<--watched> was absent), so even a genuinely bare
C<d2 tira.notify.moves> looked like a request to enable it by the time it
reached the engine. Both layers now only persist a change when one was
actually asked for; a bare read reports the current or default setting
without writing anything.

=cut
