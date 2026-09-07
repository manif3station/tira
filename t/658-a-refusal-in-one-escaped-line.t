#!/usr/bin/env perl
# TKT-658. Found reviewing TKT-598: a refusal built as several lines - the
# required-action gate's "Cannot move ... not done" message, joined with
# literal "\n" characters - reaches the reader as one string, whatever
# output format is asked for. TOON and JSON both escape the interior
# newlines (correctly - a JSON string cannot legally contain a literal
# newline), so a dozen blocking items with commands, backticks and their
# own punctuation come back as a single '\n'-riddled line nobody can read
# without mentally re-splitting it. -o human fared no better: an error had
# no template of its own, so it fell into the generic record renderer and
# came back as a JSON blob inside a markdown code fence - the escaping
# problem AND a second, unrelated one.
#
# THE FIX: a multi-line CLI error is carried as an ARRAY of lines rather
# than one string with embedded newlines. TOON and JSON then render one
# array element per line - the same "row per finding" shape TKT-291 already
# gave the police bridge for the identical reason. An ordinary single-line
# error is untouched, staying a plain string, because splitting a string
# with nothing to split is not a fix for anything.
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
my $tira = Tira->new( clock => sub {'2026-09-07T22:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Escaped Refusals', dir => $root, members => ['claude'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'ESS', epic_prefix => 'ESE', ticket_prefix => 'EST',
);
$tira->column_update(
    project => $root, type => 'ticket', name => 'implement', author => 'claude',
    required_action => [ 'Run `prove -lr t` and record what it said', 'Write the docs' ],
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'x' );

sub attempt {
    my ( $column, $format ) = @_;
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    eval {
        Tira::CLI->run(
            command => 'record.move', tira => $tira,
            argv    => [ '--type', 'ticket', '--ref', $card->{ref}, '--column', $column,
                '--author', 'claude', '-o', $format ],
        );
    };
    select $old;
    return $said // '';
}

# Through the CLI dispatch layer, same as the refusal itself - required
# items are populated there, not by the engine's own record_move. TKT-598's
# own architecture note: "Storing what a column asks for and refusing a
# move are deliberately separate."
attempt( 'implement', 'toon' );

# --- TOON: one array element per line, not one escaped string --------------
#
# JSON is deliberately left alone (the card's own test_steps ask for it
# byte-identical): a JSON string cannot legally hold a literal newline, so
# escaping it there is correct, not the fault. TOON is read as text the
# same way -o human is, which is why it gets the same fix.

{
    my $said = attempt( 'verify', 'toon' );
    require Tira::Toon;
    my $decoded = Data::TOON->decode($said);
    ok( ref $decoded->{error} eq 'ARRAY',
        '-o toon carries a multi-line refusal as an array of lines, not one string' );
    my $joined = ref $decoded->{error} eq 'ARRAY'
      ? join( "\n", @{ $decoded->{error} } )
      : ( $decoded->{error} // '' );
    like( $joined, qr/Run `prove -lr t` and record what it said/,
        "-o toon still carries the item's own text intact" );
    unlike( $joined, qr/\\n/,
        '-o toon contains no literal backslash-n - the split already happened' );
}

# --- JSON stays byte-identical: still one escaped string --------------------

{
    my $said = attempt( 'verify', 'json' );
    my $decoded = Tira::json_decode($said);
    ok( !ref $decoded->{error}, '-o json is untouched - still a plain, escaped string' );
    like( $decoded->{error}, qr/Run `prove -lr t` and record what it said/,
        'and it still carries the item text, exactly as it always did' );
}

# --- human: the error renders as its own text, not a JSON blob in a fence --

{
    my $said = attempt( 'verify', 'human' );
    unlike( $said, qr/```json/,
        'a refusal under -o human is not wrapped as a JSON code block' );
    like( $said, qr/Run `prove -lr t` and record what it said/,
        'and it still carries the item text' );
}

# --- an ordinary, single-line error is unaffected ---------------------------

{
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    eval {
        Tira::CLI->run(
            command => 'ticket.show', tira => $tira,
            argv    => [ '--ref', 'NOPE-999', '-o', 'json' ],
        );
    };
    select $old;
    my $decoded = Tira::json_decode($said);
    ok( !ref $decoded->{error}, 'a single-line error is still a plain string, not split into a one-element array' );
}

done_testing();

__END__

=head1 NAME

658-a-refusal-in-one-escaped-line.t - a multi-line CLI refusal reaches the
reader as lines, not one escaped string

=head1 DESCRIPTION

TKT-658. C<Tira::CLI::_error> now carries a message containing interior
newlines as an array of lines rather than one string - C<-o json> and
C<-o toon> then render one element per line instead of escaping every
newline into an unreadable C<\n>-riddled single value, and C<-o human>
gets a dedicated case in C<Tira::Render::_markdown> instead of falling
into the generic record renderer, which wrapped an error as a JSON blob
inside a markdown fence. An ordinary single-line error is untouched.

=cut
