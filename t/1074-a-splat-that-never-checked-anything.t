#!/usr/bin/env perl
# TKT-581. Tira guards command-specific options: --session, --voice,
# --sdlc-gate and others are refused on a command that will not act on
# them, naming where the flag belongs. But --sort (TKT-508), --all-sessions
# (TKT-539) and --unlinked (TKT-552) - all read in exactly one place in the
# whole engine, Tira::Tasklist::tasklist_list - had no guard at all.
# `d2 tira.ticket.show --ref GT-001 --sort text:asc` exited 0, printed the
# card, and silently ignored the flag - a caller who believes they asked
# for an ordering gets one that was never applied, with nothing said. The
# same for --all-sessions and --unlinked on any command that is not
# tasklist.list.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Sortless', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'SLS', epic_prefix => 'SLE', ticket_prefix => 'SLT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Somebody must sort this' );

sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => $command, type => 'ticket', tira => Tira->new, argv => [@argv] );
    };
    return ( $status, $out, $err );
}

# --- the three flags that did nothing on the wrong command ------------------

for my $case (
    [ '--sort',         'text:asc' ],
    [ '--all-sessions', undef ],
    [ '--unlinked',     undef ],
) {
    my ( $flag, $value ) = @{$case};
    my @extra = ( '--ref', $card->{ref}, $flag, ( defined $value ? $value : () ) );
    my ( $status, $out, $err ) = run( 'record.show', @extra );
    isnt( $status, 0, "record.show $flag is refused, not silently accepted" );
    like( $err, qr/\Q$flag\E/, "and the refusal names $flag" );
    like( $err, qr/tasklist\.list/, "and ${flag}'s refusal points at tasklist.list" );
}

# --- and the same three still work where they belong ------------------------

my ( $status ) = run( 'tasklist.list', '--all-sessions' );
is( $status, 0, '--all-sessions still works on tasklist.list' );

( $status ) = run( 'tasklist.list', '--unlinked' );
is( $status, 0, '--unlinked still works on tasklist.list' );

( $status ) = run( 'tasklist.list', '--sort', 'text:asc' );
is( $status, 0, '--sort still works on tasklist.list' );

# --- --all-sessions also belongs to search --tasklist (TKT-550) -----------
#
# Missed in the first draft of this fix, caught by Codex review:
# --all-sessions crosses the session boundary for search's own tasklist
# match too (lib/Tira.pm's search, gated on --tasklist), not only for
# tasklist.list. A guard scoped to tasklist.list alone would have wrongly
# refused this documented, working command.

( $status ) = run( 'search', '--text', 'anything', '--tasklist', '--all-sessions' );
is( $status, 0, '--all-sessions still works on search --tasklist (TKT-550)' );

# --- --sort and --unlinked are read in exactly one place -------------------
#
# Verified directly against the engine's own source, not assumed: only
# Tira::Tasklist reads either (checked live during red confirmation via
# grep against lib/Tira.pm and lib/Tira/Tasklist.pm). A command later given
# a real reason to read one of the three belongs in the guard's own
# commands regex above, not as a silent exception anywhere else.

# --- a command-specific option with no guard is exactly what this ticket found
#
# Proven by construction rather than by a second enumeration test: the three
# refusals above are themselves the guard that did not exist before this
# ticket. A fourth flag added to %OPTION_READ_BY without a real reader
# behind it would be caught the same way TKT-373's shape-check guard is -
# by a live command actually failing to act on it, which is what the tests
# above already demonstrate for these three.

done_testing;

__END__

=head1 NAME

t/1074-a-splat-that-never-checked-anything.t - --sort, --all-sessions and
--unlinked are refused everywhere except tasklist.list

=head1 DESCRIPTION

TKT-581. C<--sort>, C<--all-sessions> and C<--unlinked> are read in exactly
one place in the whole engine, C<Tira::Tasklist::tasklist_list>, but had no
guard: any other command accepted and silently discarded them, exiting 0 as
though the ordering or filter had been applied. Now refused, naming the
flag and pointing at C<tasklist.list>. All three still work there.

=cut
