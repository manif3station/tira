#!/usr/bin/env perl
# TKT-298. Probed live: an unknown COMMAND gets "Did you mean" from the
# dispatcher this project sits inside; an unknown OPTION got only "Unknown
# option: X" from Getopt::Long, discarded into a generic "Invalid
# command-line options" with nothing suggested. One bad option name
# discarded a whole update carrying twenty composed fields, and finding
# which flag was wrong cost writing a probe value into a live card.
#
# The same probe also found --key-detail (append, singular) and
# --key-details (typed, plural) treated inconsistently: Getopt::Long
# abbreviation lets --set-key-detail match the longer --set-key-details
# spec, but nothing makes the shorter --key-detail spec match the longer
# --key-details typo - so a caller who learns the plural from one flag
# family loses a whole command trying it on the other. Suggesting the
# near-miss (an edit distance of 1) closes that gap without changing which
# spellings are actually accepted.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Suggested', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SGS', epic_prefix => 'SGE', ticket_prefix => 'SGT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card that must not be touched by a refused call', priority => 3 );

sub run {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => 'ticket.update', tira => $tira, argv => \@argv );
    };
    return ( $status, $out . $err );
}

# --- the exact typo reported: the plural of an append-only singular flag ---

{
    my ( $status, $said ) = run( '--ref', $card->{ref}, '--key-details', 'x' );
    isnt( $status, 0, 'the typo is still refused' );
    like( $said, qr/Unknown option:\s*key-details/, 'named the way it always was' );
    like( $said, qr/Did you mean:/, 'and now offered a guess' );
    like( $said, qr/--key-detail\b/, 'naming the flag that was actually meant' );
}

# --- and nothing was written, the same atomic refusal as before ------------

{
    my $after = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    is_deeply( $after->{key_details}, [], 'the refused call wrote nothing to the card' );
}

# --- a second real typo, unrelated to the singular/plural pair -------------

{
    my ( undef, $said ) = run( '--ref', $card->{ref}, '--prioryt', '4' );
    like( $said, qr/Unknown option:\s*prioryt/, 'a different typo is named too' );
    like( $said, qr/--priority\b/, 'and a different correct flag is suggested' );
}

# --- an option too far from anything real gets no false guess --------------

{
    my ( undef, $said ) = run( '--ref', $card->{ref}, '--xyzzy-plugh-frotz', '1' );
    like( $said, qr/Unknown option:\s*xyzzy-plugh-frotz/, 'still named' );
    unlike( $said, qr/Did you mean:/,
        'but nothing is guessed when nothing is close - a wrong guess is worse than none' );
}

# --- a Getopt::Long complaint that is not "unknown option" still reaches ---
# the reader, the same as it always did - catching the unknown-option case
# must not silence every other one Getopt::Long can raise

{
    my ( undef, $said ) = run( '--ref', $card->{ref}, '--priority' );
    like( $said, qr/requires an argument/,
        "a different Getopt::Long complaint (a missing value) is not swallowed by the new capture" );
}

done_testing;

__END__

=head1 NAME

370-a-typo-that-got-no-hint.t - an unknown option now says what was meant

=head1 DESCRIPTION

An unknown option used to answer only "Unknown option: X", discarded by
the caller into a generic "Invalid command-line options" - the same help a
command typo already gets, missing for the more common typo of a flag. The
refusal now suggests the nearest declared option names by edit distance,
covering both a plain misspelling and the specific singular/plural
asymmetry TKT-298 reported (--key-detail accepts only the singular,
--key-details is a near-miss rather than a mystery). Nothing is written
before the refusal, and nothing is guessed when no declared name is close.

=cut
