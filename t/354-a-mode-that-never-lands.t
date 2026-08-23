#!/usr/bin/env perl
# tira.project.update accepts --mode, drops it, and prints the whole project
# back - the same shape TKT-281 (--sdlc-gate), TKT-302 (--comment) and TKT-431
# (--uri) each found on a record or evidence command, here on the project
# instead of a card.
#
# Measured on installed 2.62: 'tira.project.mode --mode single' answers
# {"mode":"single"}; 'tira.project.update --mode chain' exits 0 and prints
# the whole project record, and 'tira.project.mode' straight after still
# answers single - the value never landed, though the engine stores it
# perfectly well when project.mode itself sets it. TKT-382.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-23T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Landed', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'LDS', epic_prefix => 'LDE', ticket_prefix => 'LDT',
);

sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME}   = $root;
            local $ENV{TIRA_AUTHOR} = 'claude';
            Tira::CLI->run( command => $command, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# --- the drop, refused rather than silently confirmed ------------------------

{
    my ( $status, $said ) = run( 'project.update', '--mode', 'chain' );

    isnt( $status, 0, '--mode on project.update is refused' );
    like( $said, qr/--mode/, 'naming the option' );
    like( $said, qr/project\.mode/, 'and the command that actually sets it' );
}

is( $tira->project_mode( project => $root ), undef,
    'and the mode itself is unchanged - not silently applied before the refusal' );

# --- the command that does read it is untouched -------------------------------

{
    my ($status) = run( 'project.mode', '--mode', 'chain' );
    is( $status, 0, 'project.mode --mode still works, unaffected by the guard' );
}
is( $tira->project_mode( project => $root ), 'chain', 'and the value actually lands there' );

# --- the rest of project.update's surface is untouched ------------------------

{
    my ($status) = run( 'project.update', '--name', 'Landed Again' );
    is( $status, 0, '--name on project.update still works' );
}
is( $tira->project_show( project => $root )->{name}, 'Landed Again',
    'and the name actually changed' );

done_testing;

__END__

=head1 NAME

354-a-mode-that-never-lands.t - project.update refuses --mode rather than dropping it

=head1 DESCRIPTION

C<tira.project.update> accepted C<--mode>, parsed it, carried it into the
engine call, and dropped it - printing back the whole project record, which
reads as confirmation because the project is right there. The engine stores
the value perfectly well when C<tira.project.mode> itself sets it. This
proves the drop is now a refusal naming the right command, that refusing it
does not silently apply it first, that C<project.mode> itself is unaffected,
and that the rest of C<project.update>'s surface (C<--name>) still works.

=cut
