#!/usr/bin/env perl
# TKT-292. tira.usage documents no allowed values for --sdlc-gate, and
# gate.add's --gate has no documented value set either - both are free text,
# so nothing can hold them in agreement and no typo is ever refused.
# gate-missing depends on this: a misspelt or invented gate name satisfies or
# falsely reports it with no way to tell.
#
# Q-070 answered: per-project configurable, not a fixed hardcoded list -
# matching column_roles' own opt-in pattern (unrestricted until a project
# declares its own vocabulary, then validated against that list). --gate and
# --sdlc-gate share one declared vocabulary per project.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T12:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Gated', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'GTS', epic_prefix => 'GTE', ticket_prefix => 'GTT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'A card' );

# --- undeclared: exactly today's behaviour, free text on both -------------
is_deeply( $tira->project_gates( project => $root ), [], 'a fresh project declares no gate vocabulary' );

my $gate = $tira->gate_add( project => $root, ref => $card->{ref}, gate => 'nonsense',
    result => 'pass', details => 'no vocabulary declared', author => 'claude' );
is( $gate->{gate}, 'nonsense', 'undeclared, gate.add accepts any gate name, exactly as before' );

my $updated = $tira->record_update( project => $root, ref => $card->{ref}, author => 'claude',
    sdlc_gate => 'nonsense-too' );
is( $updated->{sdlc_gate}, 'nonsense-too', 'undeclared, --sdlc-gate accepts any value too' );

# --- declaring a vocabulary ------------------------------------------------
my $declared = $tira->project_gates_set( project => $root, names => [ 'G0', 'G1', 'TESTED' ] );
is_deeply( $declared, [ 'G0', 'G1', 'TESTED' ], 'declaring a vocabulary returns it, in the order given' );
is_deeply( $tira->project_gates( project => $root ), [ 'G0', 'G1', 'TESTED' ], 'and reads back the same way' );

# --- gate.add is refused for a name outside the declared vocabulary --------
my $error = eval {
    $tira->gate_add( project => $root, ref => $card->{ref}, gate => 'made-up',
        result => 'pass', details => 'x', author => 'claude' );
    1;
} ? '' : $@;
like( $error, qr/'made-up'/, 'gate.add names the refused gate' );
like( $error, qr/G0, G1, TESTED/, 'and names the declared vocabulary' );

# --- and accepted for one that is in it ------------------------------------
my $ok_gate = $tira->gate_add( project => $root, ref => $card->{ref}, gate => 'TESTED',
    result => 'pass', details => 'ran the suite', author => 'claude' );
is( $ok_gate->{gate}, 'TESTED', 'a declared gate name is accepted' );

# --- --sdlc-gate is governed by the SAME declared vocabulary ---------------
$error = eval {
    $tira->record_update( project => $root, ref => $card->{ref}, author => 'claude',
        sdlc_gate => 'made-up' );
    1;
} ? '' : $@;
like( $error, qr/'made-up'/, '--sdlc-gate names the refused value too' );
like( $error, qr/G0, G1, TESTED/, 'against the same declared list' );

my $set_ok = $tira->record_update( project => $root, ref => $card->{ref}, author => 'claude',
    sdlc_gate => 'G1' );
is( $set_ok->{sdlc_gate}, 'G1', 'a declared value is accepted on --sdlc-gate' );

# --- clearing sdlc_gate back to empty is unaffected -------------------------
my $cleared = $tira->record_update( project => $root, ref => $card->{ref}, author => 'claude',
    sdlc_gate => '' );
ok( !defined $cleared->{sdlc_gate}, 'clearing sdlc_gate to empty still works, vocabulary or not' );

# --- create_record is governed the same way ---------------------------------
$error = eval {
    $tira->create_record( project => $root, type => 'ticket', title => 'Bad at birth', sdlc_gate => 'nope' );
    1;
} ? '' : $@;
like( $error, qr/'nope'/, 'creating a card with an undeclared sdlc_gate is refused too' );

my $born_right = $tira->create_record( project => $root, type => 'ticket', title => 'Good at birth',
    sdlc_gate => 'G0' );
is( $born_right->{sdlc_gate}, 'G0', 'and a declared value at creation succeeds' );

# --- the real CLI command, both reading and declaring -----------------------
sub cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => 'project.gates', argv => \@argv );
    return ( $status, $out, $err );
}

my ( $status, $out ) = cli();
is( $status, 0, 'tira.project.gates with no arguments reads rather than writes' );
like( $out, qr/G0.*G1.*TESTED/s, 'and shows the currently declared vocabulary' );

( $status, $out ) = cli( '--gate-name', 'G0', '--gate-name', 'G2', '-o', 'json' );
is( $status, 0, 'tira.project.gates --gate-name declares a new vocabulary' );
is_deeply( $tira->project_gates( project => $root ), [ 'G0', 'G2' ],
    'and the declared set replaced the old one' );

done_testing;

__END__

=head1 NAME

381-a-gate-name-nobody-agreed-on.t - a per-project, opt-in gate vocabulary shared by --gate and --sdlc-gate

=head1 DESCRIPTION

Both tira.gate.add's --gate and record_update/create_record's --sdlc-gate
took free text with no documented value set - "measured: --sdlc-gate
accepted implement, verify, tests-red, full-suite-and-coverage AND
nonsense." TKT-292 (Q-070: per-project configurable) gives a project an
opt-in way to declare its own gate vocabulary (project_gates_set), read
back with project_gates, and validated everywhere a gate name is written
- gate_add, record_update, and create_record - once declared. A project
that never declares one is completely unaffected, matching column_roles'
own opt-in shape.
