#!/usr/bin/env perl
# TKT-669. required-action.list's default output prints every proof in
# full, so answering "which of this card's gates are still open" meant
# reading a whole card's worth of multi-paragraph evidence to find the
# handful of pending ids - and --brief, the flag built for exactly this,
# was refused with "Read options are available on show, list, and export
# commands", which reads as though required-action.list (a command with
# "list" right in its own name) should already work.
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
my $tira = Tira->new( clock => sub {'2026-09-08T00:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Briefly', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'BFS', epic_prefix => 'BFE', ticket_prefix => 'BFT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'x' );

my $long_proof = "Ran the full suite.\n" x 40;    # a real multi-paragraph proof
my $done = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
    item => 'The work itself', status => 'pending' );
$tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref},
    id => $done->{id}, status => 'done', command => ['prove -lr t'], proof => [$long_proof] );
my $pending = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
    item => 'Something still to do', status => 'pending' );

sub run {
    my (@argv) = @_;
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    my $status = eval { Tira::CLI->run( command => 'required-action.list', tira => $tira, argv => \@argv ) };
    select $old;
    return ( $status, $stdout, $said // '' );
}

# --- --brief: one line per item, no proof text ------------------------------

{
    my ( $status, $out ) = run( '--ref', $card->{ref}, '--brief', '-o', 'json' );
    is( $status, 0, '--brief on required-action.list is accepted, not refused' );
    my $decoded = $status == 0 ? Tira::json_decode($out) : [];
    is( scalar @{$decoded}, 2, 'both items are still present' );
    unlike( $out, qr/Ran the full suite/, 'the long proof text does not appear under --brief' );
    ok( ( grep { $_->{id} eq $done->{id} && $_->{status} eq 'done' } @{$decoded} ),
        'the done item is still identified by id and status' );
    ok( ( grep { $_->{id} eq $pending->{id} && $_->{status} eq 'pending' } @{$decoded} ),
        'and so is the pending one' );
}

# --- without the flag: the proof is still there, exactly as before ---------

{
    my ( undef, $out ) = run( '--ref', $card->{ref}, '-o', 'json' );
    like( $out, qr/Ran the full suite/, 'without --brief the full proof is still printed' );
}

# --- a command that genuinely does not take a read option is still refused -

{
    my ( $status, undef, $said ) = run_other_command();
    is( $status, 2, 'a command with no read-option support is still refused' );
    like( $said, qr/required-action\.list/,
        'the refusal now names required-action.list among the commands a read option works on' );
}

sub run_other_command {
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    my $status = eval {
        Tira::CLI->run( command => 'record.move', tira => $tira,
            argv => [ '--type', 'ticket', '--ref', $card->{ref}, '--column', 'implement',
                '--author', 'claude', '--brief' ] );
    };
    select $old;
    return ( $status, $stdout, $said // '' );
}

done_testing();

__END__

=head1 NAME

669-a-list-with-no-short-answer.t - required-action.list gains --brief

=head1 DESCRIPTION

TKT-669. C<required-action.list> printed every item's proof in full with
no way to shorten it, and C<--brief> - the flag that exists for exactly
this on other commands - was refused with a message that read as though
this command, which has "list" in its own name, should already work.
C<--brief> now trims each item to C<id>/C<column>/C<status>/C<item>,
dropping proof text; the CLI's own read-option guard now names
C<required-action.list> as accepting C<--brief> alone. Every other
command's refusal is unaffected.

=cut
