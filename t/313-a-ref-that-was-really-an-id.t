#!/usr/bin/env perl
# TKT-412. question.mark's refusal for a missing --id said "A question
# reference is required - supply it with --ref" - wrong on two counts: the
# field the die actually checks is always $args{id} (the question's own id),
# never $args{ref}, and the CLI's own translation table pointed the reader at
# the wrong flag. A caller who ran `tira.question.mark --ref Q-001 --mark ok`
# (mistaking --ref for the question's own reference, and never supplying
# --id) got the identical message as one who supplied nothing at all -
# "d2 tira.question.mark --ref Q-001 --mark ok" and "d2 tira.question.mark
# --mark ok" both said "A question reference is required - supply it with
# --ref", so a reader could not tell "you gave nothing" from "you gave the
# wrong thing" from the message alone.
#
# Fixed: the engine message now says "A question id is required" and CLI.pm
# hints --id, not --ref. And when --ref itself holds something shaped like a
# question id (Q-NNN) while --id is missing, the message says so distinctly -
# a card reference was expected there, not a question id.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-20T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    project => $root, name => 'Asked', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'implement' ],
    sow_prefix => 'AKS', epic_prefix => 'AKE', ticket_prefix => 'AKT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Has a question', reporter => 'claude' );
my $question = $tira->question_add( project => $root, ref => $card->{ref}, text => 'Ready to ship?' );
$tira->question_answer( project => $root, id => $question->{id}, text => 'Yes.' );

sub cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => 'question.mark', tira => $tira, argv => \@argv );
    };
    return ( $status, $out . $err );
}

# --- nothing given at all: the id is what is missing, and CLI says so ------
{
    my ( $status, $said ) = cli( '--mark', 'ok' );
    isnt( $status, 0, 'question.mark with nothing given is refused' );
    like( $said, qr/A question id is required/, 'the engine names what it actually checked' );
    like( $said, qr/--id\b/, 'and the CLI hints --id' );
    unlike( $said, qr/--ref\b/, 'not --ref, which was never asked for' );
}

# --- a question id given as --ref, --id left out: a distinct mistake -------
{
    my ( $status, $said ) = cli( '--ref', $question->{id}, '--mark', 'ok' );
    isnt( $status, 0, 'question.mark with the question id given as --ref is refused' );
    like( $said, qr/\Q$question->{id}\E/, 'names what was actually given' );
    like( $said, qr/question id/, 'and says it looks like a question id' );
    like( $said, qr/--id\b/, 'pointing at --id instead' );
}

# --- and this is genuinely a different message from the empty-call one -----
{
    my ( undef, $empty ) = cli( '--mark', 'ok' );
    my ( undef, $misdirected ) = cli( '--ref', $question->{id}, '--mark', 'ok' );
    isnt( $empty, $misdirected, 'a caller can tell "gave nothing" from "gave the wrong thing"' );
}

# --- an --id that IS given, with a --ref naming a real different card ------
# unaffected: the existing cross-check message is untouched.
{
    my $other = $tira->create_record( project => $root, type => 'ticket', title => 'Not the one', reporter => 'claude' );
    my ( $status, $said ) = cli( '--id', $question->{id}, '--ref', $other->{ref}, '--mark', 'ok' );
    isnt( $status, 0, 'a genuinely mismatched card is still refused' );
    like( $said, qr/is on \Q$card->{ref}\E, not on \Q$other->{ref}\E/,
        'with the existing, already-clear cross-check message, unchanged' );
}

# --- and the ordinary, correct call is entirely unaffected -----------------
{
    my ( $status, $said ) = cli( '--id', $question->{id}, '--mark', 'ok' );
    is( $status, 0, 'the ordinary call - just --id - still works' ) or diag($said);
}

done_testing;

__END__

=head1 NAME

313-a-ref-that-was-really-an-id.t - question.mark names what is actually missing, and what was actually given

=head1 DESCRIPTION

Covers TKT-412: the refusal for a missing --id on question.mark (and its
siblings, which share the same _question_owner helper) now says "A question
id is required" and the CLI hints --id, not --ref. When --ref itself holds
something shaped like a question id while --id is missing, the message names
that distinctly. The existing cross-check for a genuinely mismatched --ref
(when --id is given) is unchanged.

=cut
