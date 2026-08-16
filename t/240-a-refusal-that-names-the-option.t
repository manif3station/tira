#!/usr/bin/env perl
# A command that needs a type says so, in the words somebody would type.
#
# He met this on tira.column.list: running it answered
#
#     error: Unsupported record type ''
#
# while --help printed a usage line with no --type in it, and --type ticket
# worked. So the option that is required was absent from the usage, the refusal
# named an internal concept rather than the thing left out, and the only way
# from one to the other was guessing.
#
# He named the standard himself, and it is this project's own: tira.policy.add
# refuses with "Policy rule card-sandbox-missing needs --enter", which takes no
# guessing at all.
#
# Five commands, not one. Running every entrypoint with no arguments from
# inside a board turns up the same sentence from tira.board.refs,
# tira.board.show, tira.column.list, tira.column.sync and tira.column.update -
# and they all reach it through one place, so fixing the command he happened to
# meet would have left four saying the same unhelpful thing.
#
# The same family as three faults reported from outside this project: a refusal
# that did not name the command to run, a violation that pointed at a viewer
# rather than the repair, and a doctor that listed damage and named nothing to
# fix it. A message that says no without saying where to go.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Typed', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'TYS', epic_prefix => 'TYE', ticket_prefix => 'TYT',
);

sub run {
    my (@argv) = @_;
    my $command = shift @argv;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => $command, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# --- the five commands that ask for a type -----------------------------------

my @needing = qw(board.refs board.show column.list column.sync column.update);

for my $command (@needing) {
    my ( $status, $said ) = run($command);

    isnt( $status, 0, "$command with no type is refused" );

    # non-empty is the whole claim for the assertions below, which would all
    # pass against a command that said nothing at all.
    like( $said, qr/\S/, "$command says something about it" );

    like( $said, qr/--type/, "$command names the option that is missing" );
    like( $said, qr/\bticket\b/,
        "$command names a value it would accept, so there is nothing to guess" );
    unlike( $said, qr/record type/i,
        "$command does not answer with an internal concept" );
}

# --- while supplying it behaves exactly as before ----------------------------
#
# A fix to a message must not become a fix to behaviour.

{
    my ( $status, $said ) = run( 'column.list', '--type', 'ticket', '-o', 'json' );
    is( $status, 0, 'a command given its type still answers' );
    like( $said, qr/backlog/, 'with the board\'s own columns' );
}

# --- and a type that is not one of the three ---------------------------------
#
# Given something to work with, the refusal is about what was typed rather than
# about what was left out - and still says what would be accepted.

{
    my ( $status, $said ) = run( 'column.list', '--type', 'sprint' );
    isnt( $status, 0, 'a type the board does not have is still refused' );
    like( $said, qr/sprint/, 'naming what was actually typed' );
    like( $said, qr/\bticket\b/, 'and what it would have taken' );
}

# --- and the usage line names it ---------------------------------------------
#
# The half that made the message worse: a reader who checked the usage first
# was told the opposite of the truth.

{
    my ( undef, $said ) = run( 'column.list', '--help' );
    like( $said, qr/--type/,
        'the usage line names the option the command cannot work without' );
}

done_testing;

__END__

=head1 NAME

240-a-refusal-that-names-the-option.t - saying no, and saying where to go

=head1 DESCRIPTION

Five commands answered a missing C<--type> with "Unsupported record type ''",
an internal concept rather than the option left out, while the usage line named
no option at all. They reach that refusal through one place, so all five are
covered here: refused, naming C<--type>, naming a value it would accept, and
not answering in a vocabulary the caller never used.

=cut
