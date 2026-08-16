#!/usr/bin/env perl
# A command refuses an option it will not act on.
#
# tira.assign.set takes --person. It also accepted --assignee, because the
# parser is shared and knows that option for other commands, and then threw it
# away: the card came back with the assignee still empty, the command exited
# zero, and the whole record was printed as though something had happened. On
# the one command whose job is setting the assignee, the obvious flag name was
# the one that silently did nothing.
#
# It cost two attempts and a screenshot from the owner - "implementing but no
# assignee? a ghost working on it?" - before anybody noticed a card had sat in
# implement for an hour with nobody on it.
#
# The same shape turned up again the same day inside the engine: a policy's
# read age was accepted, validated, carried through the CLI and then dropped,
# because policies store only the fields in one list and it was not in it. That
# one the tests caught. This one nothing would have.
#
# This is narrow on purpose. There is no per-command list of the options each
# one uses, and inventing one for 138 commands would refuse things that work
# today. What is declared here is the small set where one option names the job
# another option does - which is the set that misleads, because the wrong name
# looks accepted rather than unknown.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T20:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Who has it', dir => $root, members => [ 'michael', 'ada' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WHS', epic_prefix => 'WHE', ticket_prefix => 'WHT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Somebody must hold this' );

sub run {
    my ( $command, @argv ) = @_;

    # Mirror the installed dispatcher: a board command carries its type
    # separately, so ticket.update reaches the engine as record.update on a
    # ticket. Passing it the way a person types it is an unsupported command,
    # which is a different failure from the one being tested.
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => $command, type => $type, tira => $tira,
            argv => [ @argv ] ) };
    };
    return ( $status, $out, $err );
}

# --- the flag that did nothing ---------------------------------------------------

my ( $status, $out, $err ) = run( 'assign.set', '--ref', $card->{ref}, '--assignee', 'ada' );
isnt( $status, 0, 'assign.set refuses --assignee rather than ignoring it' );
like( $err, qr/--person/, 'and names the option that does what was meant' );
is( $tira->record_show( project => $root, ref => $card->{ref} )->{assignee}, undef,
    'and nothing was assigned, which is what the old behaviour looked like but did not say' );

# --- the flag that works -----------------------------------------------------------

( $status ) = run( 'assign.set', '--ref', $card->{ref}, '--person', 'ada' );
is( $status, 0, 'and --person still sets it' );
is( $tira->record_show( project => $root, ref => $card->{ref} )->{assignee}, 'ada',
    'so the card really is held by somebody' );

# --- and the same for the commands beside it ---------------------------------------
#
# assign.add and assign.remove take the same option and would mislead the same
# way. Fixing only the one somebody happened to hit is how two commands that
# agree today drift apart tomorrow.

for my $command (qw(assign.add assign.remove)) {
    my ( $refused, undef, $said ) = run( $command, '--ref', $card->{ref}, '--assignee', 'ada' );
    isnt( $refused, 0, "$command refuses --assignee too" );
    like( $said, qr/--person/, "and $command says which option to use" );
}

# --- while every other command is untouched -----------------------------------------
#
# --assignee is a real option elsewhere: it is how a card's assignee is set on
# the card itself. Refusing it there would break the thing it is for.

( $status ) = run( 'ticket.update', '--ref', $card->{ref}, '--assignee', 'michael' );
is( $status, 0, 'a command that uses --assignee still accepts it' );
is( $tira->record_show( project => $root, ref => $card->{ref} )->{assignee}, 'michael',
    'and acts on it' );

# --- and an option nobody declared is still unknown ----------------------------------
#
# This adds refusals for options the parser knows; it must not turn an unknown
# option into a different kind of error.

( $status, undef, $err ) = run( 'assign.set', '--ref', $card->{ref}, '--nonsense', 'ada' );
isnt( $status, 0, 'an option that does not exist is still refused' );
like( $err, qr/Unknown option|Invalid command-line/i, 'as an unknown option, not as a misused one' );

done_testing;

__END__

=head1 NAME

138-an-option-that-does-nothing.t - a command refuses an option it will not act on

=head1 DESCRIPTION

C<tira.assign.set> takes C<--person> and also accepted C<--assignee>, which it
then discarded: the card came back unchanged, the command exited zero, and the
full record was printed as though something had happened.

The commands that assign now refuse C<--assignee> and name C<--person>. It is
deliberately narrow - there is no per-command list of the options each one uses,
and inventing one for every command would refuse things that work today. What is
declared is the set where one option names the job another does, which is the
set that misleads.

=cut
