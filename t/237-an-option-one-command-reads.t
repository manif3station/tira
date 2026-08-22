#!/usr/bin/env perl
# An option every command parses and one command reads.
#
# --field names the field tira.history is about. It is in the shared parser, so
# every command takes it, and exactly one reads it. On a record update it was
# parsed, stored and dropped: the command exited zero and printed the card
# back, which reads as confirmation because the card is right there.
#
# It cost an hour of this project's own time. I raised TKT-261 from a bug hunt,
# filled it in with six --field arguments, watched the command succeed, and the
# push gate then refused the release because the card was still a title. Two
# cards' worth of writing went nowhere and nothing said so.
#
# The same shape as t/138, and the reason that guard is narrow applies here
# too: there is no per-command list of the options each one uses, and inventing
# one for every command would refuse things that work today. What is declared
# is an option whose readers are known, refused everywhere else.

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
    name => 'Fielded', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'FDS', epic_prefix => 'FDE', ticket_prefix => 'FDT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card somebody tried to fill in' );

sub run {
    my ( $command, @argv ) = @_;

    # Mirror the installed dispatcher: a board command carries its type
    # separately, so ticket.update reaches the engine as record.update.
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            $ENV{TIRA_AUTHOR} = 'claude';
            Tira::CLI->run( command => $command, type => $type, tira => $tira,
                argv => [@argv] );
        };
    };
    return ( $status, $out, $err );
}

# --- what an hour of writing looked like -------------------------------------

my ( $status, undef, $err ) = run( 'ticket.update', '--ref', $card->{ref},
    '--field', 'key_details+=What was measured.' );

isnt( $status, 0, 'a record update refuses --field rather than dropping it' );
like( $err, qr/--key-detail/,
    'and names an option that does set what was being written' );
is_deeply( $tira->record_show( project => $root, ref => $card->{ref} )->{key_details},
    [], 'and nothing was written, which is what the old behaviour did without saying so' );

# --- the option that does it -------------------------------------------------

( $status ) = run( 'ticket.update', '--ref', $card->{ref},
    '--key-detail', 'What was measured.' );
is( $status, 0, 'and the option that sets it still works' );
is_deeply( $tira->record_show( project => $root, ref => $card->{ref} )->{key_details},
    ['What was measured.'], 'so the card really did take it' );

# --- and the command that reads --field --------------------------------------
#
# The half that must not be lost. tira.history is what the option is for, and a
# refusal that catches it would trade a silent failure for a broken command.

{
    my ( $asked, $said ) = run( 'history.list', '--ref', $card->{ref}, '--field', 'key_details' );
    is( $asked, 0, 'the command that reads --field still takes it' );

    # non-empty is the whole claim: an empty answer would satisfy any
    # assertion about what the history does not contain.
    like( $said, qr/\S/, 'and answers with something' );
    like( $said, qr/key_details/, 'about the field it was asked about' );
}

# --- proved by accepting it again --------------------------------------------
#
# With the refusal taken away, the update passes and writes nothing, which is
# exactly what an hour of this project's own writing did.

{
    no warnings 'redefine';
    local *Tira::CLI::_refuse_unread_options = sub { return };

    my $other = $tira->create_record( project => $root, type => 'ticket',
        title => 'The same attempt without the refusal' );
    my ($allowed) = run( 'ticket.update', '--ref', $other->{ref},
        '--field', 'key_details+=What was measured.' );

    is( $allowed, 0, 'without it the command reports success' );
    is_deeply( $tira->record_show( project => $root, ref => $other->{ref} )->{key_details},
        [], 'having written nothing at all' );
}

# --- while an option nobody declared is still unknown ------------------------

{
    my ( $unknown, undef, $said ) = run( 'ticket.update', '--ref', $card->{ref},
        '--not-an-option', 'x' );
    isnt( $unknown, 0, 'an option that does not exist is still an error' );
    unlike( $said, qr/--key-detail/,
        'and is not answered as though it were this one' );
}

done_testing;

__END__

=head1 NAME

237-an-option-one-command-reads.t - parsed by every command, read by one

=head1 DESCRIPTION

C<--field> names the field C<tira.history> reports on. The parser is shared, so
every command accepts it, and every other command dropped it: a record update
given C<--field> exited zero, printed the card, and wrote nothing.

It is refused where it is not read, naming the options that do set a field.
C<tira.history> is unaffected, because that is the command the option is for.

=cut
