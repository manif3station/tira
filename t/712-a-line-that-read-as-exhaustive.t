#!/usr/bin/env perl
# TKT-712. checklist.add and checklist.update's usage lines named every
# argument they take except --author, which is mandatory (via
# Tira::_require_author) - so a caller composing a call from the usage
# line alone, with no TIRA_AUTHOR set, was refused with no hint which
# argument was missing. tira.TYPE.update's generic line had the identical
# gap, for the same reason (record_update also requires an author).
# tira.TYPE.move, gate.add and evidence.add already document it correctly
# as [--author NAME] - checklist.add/checklist.update/TYPE.update now
# match that convention rather than omitting it.
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
    name => 'Exhaustive', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ELS', epic_prefix => 'ELE', ticket_prefix => 'ELT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'x', author => 'claude' );

# --- the documented usage lines themselves name --author ------------------
# The underlying refusal was never the bug - Tira::_require_author already
# worked. The bug was the usage line composed from, which named every other
# argument and silently dropped this one, reading as exhaustive. TKT-575
# fixed this exact shape for --command/--proof; it had not reached --author.

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read '$path': $!";
    local $/;
    return <$fh>;
}

my $skills = read_file('SKILLS.md');
my $commands_md = read_file('docs/commands.md');

for my $line ( grep { /^tira\.checklist\.add / } split /\n/, $skills ) {
    like( $line, qr/--author/, "SKILLS.md's tira.checklist.add usage line names --author" );
}
for my $line ( grep { /^tira\.checklist\.update / } split /\n/, $skills ) {
    like( $line, qr/--author/, "SKILLS.md's tira.checklist.update usage line names --author" );
}
for my $line ( grep { /`tira\.TYPE\.update / } split /\n/, $commands_md ) {
    like( $line, qr/--author/, "docs/commands.md's tira.TYPE.update usage line names --author" );
}
for my $line ( grep { /^- `tira\.checklist\.add / } split /\n/, $commands_md ) {
    like( $line, qr/\[--author NAME\]/, "docs/commands.md's tira.checklist.add usage line names --author" );
}
for my $line ( grep { /^- `tira\.checklist\.update / } split /\n/, $commands_md ) {
    like( $line, qr/\[--author NAME\]/, "docs/commands.md's tira.checklist.update usage line names --author" );
}
for my $line ( grep { /^tira\.required-action\.add / } split /\n/, $skills ) {
    like( $line, qr/--author/, "SKILLS.md's tira.required-action.add usage line names --author" );
}
for my $line ( grep { /^tira\.comment\.update / } split /\n/, $skills ) {
    like( $line, qr/--author/, "SKILLS.md's tira.comment.update usage line names --author" );
}

sub run {
    my ( $command, @argv ) = @_;
    my %type_for = ( 'ticket.update' => 'ticket' );
    my $type = $type_for{$command};
    $command = 'record.update' if $command eq 'ticket.update';
    local $ENV{TIRA_HOME}    = $root;
    delete local $ENV{TIRA_AUTHOR};
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    my $status = eval { Tira::CLI->run(
        command => $command, ( defined $type ? ( type => $type ) : () ), tira => $tira, argv => \@argv ) };
    select $old;
    return ( $status, $stdout, $said // '' );
}

# --- a call composed from checklist.add's usage line, --author included ---

{
    my ( $status, undef, $said ) = run( 'checklist.add',
        '--ref', $card->{ref}, '--item', 'do it', '--status', 'pending', '--author', 'claude' );
    is( $status, 0, 'checklist.add succeeds when composed with --author, as its usage line requires' )
      or diag($said);
}

# --- omitting --author (and no TIRA_AUTHOR) refuses, naming --author -----

{
    my ( $status, undef, $said ) = run( 'checklist.add',
        '--ref', $card->{ref}, '--item', 'do it again', '--status', 'pending' );
    isnt( $status, 0, 'checklist.add without --author and no TIRA_AUTHOR is refused' );
    like( $said, qr/--author/, 'and the refusal names --author' );
}

# --- checklist.update: identical shape ------------------------------------

{
    my ($chk) = grep { 1 } @{ $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} )->{checklist} };
    my ( $status, undef, $said ) = run( 'checklist.update',
        '--ref', $card->{ref}, '--id', $chk->{id}, '--item', 'renamed', '--author', 'claude' );
    is( $status, 0, 'checklist.update succeeds when composed with --author' ) or diag($said);

    ( $status, undef, $said ) = run( 'checklist.update',
        '--ref', $card->{ref}, '--id', $chk->{id}, '--item', 'renamed again' );
    isnt( $status, 0, 'checklist.update without --author is refused' );
    like( $said, qr/--author/, 'naming --author' );
}

# --- ticket.update: the generic record-update usage line -----------------

{
    my ( $status, undef, $said ) = run( 'ticket.update',
        '--ref', $card->{ref}, '--title', 'A new title', '--author', 'claude' );
    is( $status, 0, 'ticket.update succeeds when composed with --author' ) or diag($said);

    ( $status, undef, $said ) = run( 'ticket.update', '--ref', $card->{ref}, '--title', 'Yet another' );
    isnt( $status, 0, 'ticket.update without --author is refused' );
    like( $said, qr/--author/, 'naming --author' );
}

# --- required-action.add and comment.update: same shape, real behavior ---

{
    my ( $status, undef, $said ) = run( 'required-action.add',
        '--ref', $card->{ref}, '--item', 'gate this', '--status', 'pending', '--author', 'claude' );
    is( $status, 0, 'required-action.add succeeds when composed with --author' ) or diag($said);

    ( $status, undef, $said ) = run( 'required-action.add',
        '--ref', $card->{ref}, '--item', 'gate that', '--status', 'pending' );
    isnt( $status, 0, 'required-action.add without --author is refused' );
    like( $said, qr/--author/, 'naming --author' );
}

{
    my $c = $tira->comment_add( project => $root, type => 'ticket', ref => $card->{ref},
        text => 'original', author => 'claude' );
    my ( $status, undef, $said ) = run( 'comment.update',
        '--ref', $card->{ref}, '--comment', $c->{id}, '--text', 'edited', '--author', 'claude' );
    is( $status, 0, 'comment.update succeeds when composed with --author' ) or diag($said);

    ( $status, undef, $said ) = run( 'comment.update', '--ref', $card->{ref}, '--comment', $c->{id}, '--text', 'edited again' );
    isnt( $status, 0, 'comment.update without --author is refused' );
    like( $said, qr/--author/, 'naming --author' );
}

done_testing();

__END__

=head1 NAME

712-a-line-that-read-as-exhaustive.t - checklist.add, checklist.update and
TYPE.update's usage lines now name the --author their engine requires

=head1 DESCRIPTION

TKT-712. C<checklist_add>, C<checklist_update> and C<record_update> all
call C<Tira::_require_author>, which refuses with no C<--author> and no
C<TIRA_AUTHOR> in the environment - but the commands' own usage lines
named every optional flag except that one, so a call composed from the
usage line alone was refused with no hint which argument was missing.
Fixed in SKILLS.md and docs/commands.md, matching the C<[--author NAME]>
convention C<TYPE.move>, C<gate.add> and C<evidence.add> already use.

=cut
