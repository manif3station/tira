#!/usr/bin/env perl
# Discarding with a reason either records it or refuses.
#
# Reproduced twice in ten minutes by accident on this project's own board:
# TKT-297 and TKT-294 were discarded with --comment carrying the reason, both
# came back with no comments, and discard-unexplained fired on both within the
# minute. Each time the discard exited 0 and printed the whole card, which
# reads as confirmation because the card is right there.
#
# --comment is a real option - declared at lib/Tira/CLI.pm and read by the
# comment commands and by attachment.discard - and record.discard never looks
# at it. The same shape as --sdlc-gate on move (TKT-281) and --field before it.
#
# It costs more than either. The dropped value is the reason a card was set
# aside, and discard-unexplained exists precisely to require that reason: so
# the option that looks like the way to satisfy the rule is the one way that
# cannot. Refused rather than made to work, for the reason TKT-281 gives -
# teaching discard to carry the comment later is an addition, un-teaching
# callers that it works is not.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-18T01:25:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Reasoned', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'RNS', epic_prefix => 'RNE', ticket_prefix => 'RNT',
);

sub run {
    my ( $command, @argv ) = @_;
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
            Tira::CLI->run( command => $command, type => $type, tira => $tira,
                argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# --- a discard given a reason ----------------------------------------------------

{
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Set aside for a reason somebody typed' );

    my ( $status, $said ) = run( 'ticket.discard', '--ref', $card->{ref},
        '--comment', 'Duplicate of RNT-999, which carries the work.' );

    isnt( $status, 0, 'a discard given a reason it will not record is refused' );
    like( $said, qr/--comment/, 'naming the option it does not act on' );
    like( $said, qr/comment\.add/, 'and the command that does record a reason' );

    is( $tira->record_show( project => $root, ref => $card->{ref} )->{column},
        'backlog',
        'and the card is not discarded either, so nothing is half-done' );
}

# --- while a discard with no reason works as it always did -------------------------
#
# The rule that requires a reason is discard-unexplained's, not this refusal's.
# Making discard refuse without one would be a different card and a wrong one.

{
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Set aside with the reason given afterwards' );

    my ($status) = run( 'ticket.discard', '--ref', $card->{ref} );
    is( $status, 0, 'a discard with no reason still works' );
    is( $tira->record_show( project => $root, ref => $card->{ref} )->{column},
        'discard', 'and the card is discarded' );

    my ($commented) = run( 'comment.add', '--ref', $card->{ref},
        '--author', 'claude', '--text', 'Duplicate; the work is on RNT-999.' );
    is( $commented, 0, 'and the reason goes on with the command that records one' );
}

# --- and the comment commands are untouched ----------------------------------------

{
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Commented in the ordinary way' );
    my ($status) = run( 'comment.add', '--ref', $card->{ref},
        '--author', 'claude', '--text', 'An ordinary comment.' );
    is( $status, 0, 'comment.add still reads --text' );
}

# --- proved by accepting the option again ------------------------------------------
#
# With the refusal removed, the discard succeeds and the reason is gone, which
# is the state that fired discard-unexplained twice on the real board.

{
    no warnings 'redefine';
    local *Tira::CLI::_refuse_unread_options = sub { return };

    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Discarded with a reason that vanishes' );
    my ($status) = run( 'ticket.discard', '--ref', $card->{ref},
        '--comment', 'This reason is about to disappear.' );

    is( $status, 0, 'without the refusal the discard reports success' );
    is( scalar @{ $tira->record_show( project => $root, ref => $card->{ref} )->{comments} // [] },
        0, 'while the reason it was given is nowhere on the card' );
}

done_testing;

__END__

=head1 NAME

264-a-reason-a-discard-dropped.t - the reason a discard would not record

=head1 DESCRIPTION

C<tira.<type>.discard> accepted C<--comment>, dropped it, and exited 0 printing
the whole card. It happened twice in ten minutes on this project's own board and
C<discard-unexplained> fired both times - so the option that looks like the way
to satisfy that rule was the one way that could not.

=cut
