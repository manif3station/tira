#!/usr/bin/env perl
# record_move itself now refuses a caller that supplies no author, closing
# the gap ZSD-247 found: two moves with no author recorded skipped nine
# columns' worth of chain and required-action checks, because both checks
# live only in Tira::CLI's dispatch layer (TKT-426, TKT-452), never in
# record_move itself. A script calling the engine directly - not through
# the CLI, not through the browser dashboard - had no check to skip and no
# name to skip it under.
#
# Scoped deliberately to record_move alone. The owner's answer to the scope
# question (Q-060 on this ticket): record_move first, ask again before
# extending the same rule to any other mutating command family.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-21T20:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Named', dir => $root, members => [ 'claude', 'ada' ],
    columns => [ 'backlog, doing, done' ],
    sow_prefix => 'NMS', epic_prefix => 'NME', ticket_prefix => 'NMT',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Moved by whom' );

# --- the engine itself refuses, not only the CLI dispatch layer -------------

eval { $tira->record_move( project => $root, ref => $card->{ref}, column => 'doing' ) };
like( $@, qr/A move needs to say who is making it/,
    'record_move with no author at all is refused' );

eval { $tira->record_move( project => $root, ref => $card->{ref}, column => 'doing', author => '' ) };
like( $@, qr/A move needs to say who is making it/,
    'an empty string author is refused the same way' );

is( $tira->record_show( project => $root, ref => $card->{ref} )->{column}, 'backlog',
    'a refused move leaves the card exactly where it was' );

eval { $tira->record_move( project => $root, ref => $card->{ref}, column => 'doing', author => 'nobody-registered' ) };
like( $@, qr/Unknown project person/,
    'an author naming nobody the project knows is refused too, not silently accepted' );

# --- a real author succeeds, exactly as before -------------------------------

my $moved = $tira->record_move( project => $root, ref => $card->{ref}, column => 'doing', author => 'ada' );
is( $moved->{column}, 'doing', 'a move with a real author succeeds' );

# --- record_discard and record_restore go through record_move, so they inherit it --

eval { $tira->record_discard( project => $root, ref => $card->{ref} ) };
like( $@, qr/A move needs to say who is making it/,
    'record_discard with no author is refused, since it is record_move underneath' );

$tira->record_discard( project => $root, ref => $card->{ref}, author => 'ada' );
is( $tira->record_show( project => $root, ref => $card->{ref} )->{column}, 'discard',
    'a real author discards the card as always' );

eval { $tira->record_restore( project => $root, ref => $card->{ref} ) };
like( $@, qr/A move needs to say who is making it/,
    'record_restore with no author is refused the same way' );

$tira->record_restore( project => $root, ref => $card->{ref}, author => 'ada' );
is( $tira->record_show( project => $root, ref => $card->{ref} )->{column}, 'backlog',
    'a real author restores the card as always' );

# --- the CLI dispatch layer resolves --author or TIRA_AUTHOR before this is ever reached --
#
# Not new behaviour - _invoke already read --author and TIRA_AUTHOR into
# every command before this ticket. What is new is that record.move now has
# no third way through: neither flag nor environment leaves it refused,
# with a corrective message rather than a silent no-op.

sub cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    local *STDOUT = $so;
    local *STDERR = $se;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => 'record.move', type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

my ( $status, $out, $err ) = cli( '--ref', $card->{ref}, '--column', 'doing' );
isnt( $status, 0, 'the CLI refuses a move with neither --author nor TIRA_AUTHOR' );
like( $err, qr/--author/, 'and names --author as the corrective command' );

( $status, $out, $err ) = cli( '--ref', $card->{ref}, '--column', 'doing', '--author', 'ada' );
is( $status, 0, 'the CLI move succeeds once --author is supplied' );

{
    local $ENV{TIRA_AUTHOR} = 'claude';
    ( $status, $out, $err ) = cli( '--ref', $card->{ref}, '--column', 'done' );
    is( $status, 0, 'and succeeds from TIRA_AUTHOR alone, exactly as any other command already did' );
}

done_testing;

__END__

=head1 NAME

322-a-move-with-no-name-on-it.t - record_move refuses a caller with no author

=head1 DESCRIPTION

Closes the ZSD-247 gap directly, at the layer it actually happened in.
C<_column_chain_violation> and C<_column_required_action_violation> are
checked only in C<Tira::CLI>'s C<record.move> dispatch (TKT-426, TKT-452) -
deliberately, so a signed-in browser move is exempt from them. But nothing
stopped an unattributed caller reaching C<record_move> some other way
entirely, skipping both checks with no record of who or what moved the
card.

C<record_move> now refuses outright when no author is given, or when the
given author is empty or unknown to the project - the same standard
C<--assignee> and C<--reporter> already meet. C<record_discard> and
C<record_restore> inherit this since both call C<record_move> underneath.
The CLI already resolved C<--author> or C<TIRA_AUTHOR> before this ticket;
what changes is that reaching C<record_move> with neither is now refused
with a corrective message rather than silently recorded against nobody.

Scoped to C<record_move> alone by the owner's own answer to this ticket's
scope question - other mutating commands are separate, future tickets.

=cut
