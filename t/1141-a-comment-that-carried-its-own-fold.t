#!/usr/bin/env perl
# TKT-1090. Satisfying conversation-not-folded after a substantial comment
# needs a second, separate command (tira.<type>.update --key-detail)
# restating the same information in a durable field - comment_add has no
# path to do both in one call, a real friction hit dozens of times over the
# course of this project's own work and already recorded in the agent's own
# cross-session memory before this ticket existed to file it as a real board
# item.
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
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub { '2026-09-21T00:00:00Z' } );
$tira->project_new(
    name => 'Fold', dir => $root, members => ['claude'],
    columns    => ['backlog, implement, done'],
    sow_prefix => 'FDS', epic_prefix => 'FDE', ticket_prefix => 'FDT',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'A card worth folding' );

sub cli {
    my (@argv) = @_;
    my $command = shift @argv;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => $command, argv => \@argv, tira => $tira, type => 'ticket' );
    return ( $status, $out, $err );
}

# --- one call writes both the comment and the key_detail -------------------

my ( $status, undef, $err ) = cli(
    'comment.add', '--ref', $card->{ref}, '--author', 'claude',
    '--text', 'A substantial finding worth remembering',
    '--key-detail', 'The durable version of the same finding',
);
is( $status, 0, 'comment.add --key-detail succeeds in one call' ) or diag("stderr: $err");

my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
is( scalar @{ $shown->{comments} }, 1, 'the comment was written' );
is( $shown->{comments}[0]{body}, 'A substantial finding worth remembering', 'with the right text' );
is_deeply( $shown->{key_details}, ['The durable version of the same finding'],
    'and the key_detail was written in the same call, without a second command' );

# --- without --key-detail, behavior is exactly as before --------------------

( $status, undef, $err ) = cli(
    'comment.add', '--ref', $card->{ref}, '--author', 'claude',
    '--text', 'A plain comment with nothing durable in it',
);
is( $status, 0, 'comment.add without --key-detail still succeeds, unchanged' ) or diag("stderr: $err");
$shown = $tira->record_show( project => $root, ref => $card->{ref} );
is( scalar @{ $shown->{comments} }, 2, 'a second comment was written' );
is_deeply( $shown->{key_details}, ['The durable version of the same finding'],
    'and key_details is untouched - a plain comment.add never writes to it' );

# --- an empty --key-detail is refused the same way an empty --text is ------

( $status, undef, $err ) = cli(
    'comment.add', '--ref', $card->{ref}, '--author', 'claude',
    '--text', 'Text is fine', '--key-detail', '   ',
);
isnt( $status, 0, 'a whitespace-only --key-detail is refused, not silently accepted as empty content' );
$shown = $tira->record_show( project => $root, ref => $card->{ref} );
is( scalar @{ $shown->{comments} }, 2, 'and nothing was written for the refused call - not even the comment half' );

# --- --key-detail is repeatable, and order is preserved ---------------------

( $status, undef, $err ) = cli(
    'comment.add', '--ref', $card->{ref}, '--author', 'claude',
    '--text', 'A comment with two durable findings',
    '--key-detail', 'First finding', '--key-detail', 'Second finding',
);
is( $status, 0, 'comment.add accepts --key-detail more than once' ) or diag("stderr: $err");
$shown = $tira->record_show( project => $root, ref => $card->{ref} );
is_deeply( $shown->{key_details},
    [ 'The durable version of the same finding', 'First finding', 'Second finding' ],
    'both key_details were appended, in the order given' );

# --- a valid --key-detail followed by a whitespace-only one still refuses ---
# the WHOLE call - Codex review: a validate-then-write design could still
# let SOME entries through if the loop wrote as it validated rather than
# validating everything up front.

my $before_comments = scalar @{ $shown->{comments} };
my $before_key_details = scalar @{ $shown->{key_details} };
( $status, undef, $err ) = cli(
    'comment.add', '--ref', $card->{ref}, '--author', 'claude',
    '--text', 'Should never be written',
    '--key-detail', 'A genuinely good one', '--key-detail', '   ',
);
isnt( $status, 0, 'one bad entry in a --key-detail list refuses the whole call, not just the bad one' );
$shown = $tira->record_show( project => $root, ref => $card->{ref} );
is( scalar @{ $shown->{comments} }, $before_comments, 'no comment was written' );
is( scalar @{ $shown->{key_details} }, $before_key_details,
    'and NEITHER key_detail was written - not even the good one ahead of the bad one' );

done_testing;

__END__

=head1 NAME

1141-a-comment-that-carried-its-own-fold.t - comment.add --key-detail writes
both in one call

=head1 DESCRIPTION

TKT-1090. Folding a substantial comment into a card's durable key_details
field (satisfying the conversation-not-folded rule) used to need a second,
separate C<tira.<type>.update --key-detail> call restating the same text -
a friction this project's own work hit repeatedly. C<comment.add> now
accepts C<--key-detail> and writes to both C<comments> and C<key_details>
in the same call, atomically (a refused call - a whitespace-only
key-detail - writes neither half). Omitting the flag leaves behavior
exactly as it was.

=cut
