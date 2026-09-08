#!/usr/bin/env perl
# TKT-689. %SUPPLIED_BY (Tira::CLI::Usage) maps an engine message to the flag
# that supplies it, keyed by message alone. When two commands raise the same
# message but spell the concept differently, the table gives one answer and
# it is wrong for the other.
#
# Hit live twice: ticket.move's "Invalid column name" (which really wants
# --column) got the table's --name answer, because column.add/rename/move
# also raise "Invalid column name" and do take --name. And
# hierarchy.link's "Record reference is required" got --ref, which
# hierarchy.link does not take at all - it wants --parent and --child.
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
my $tira = Tira->new( clock => sub {'2026-09-08T14:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Named Right', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'NRS', epic_prefix => 'NRE', ticket_prefix => 'NRT',
);
my $epic   = $tira->create_record( project => $root, type => 'epic', title => 'Parent' );
my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Child' );

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
            local $ENV{TIRA_AUTHOR} = 'claude';
            Tira::CLI->run( command => $command, type => $type, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# --- ticket.move: the message is right, the flag it named was not ----------

{
    my ( $status, $said ) = run( 'ticket.move', '--ref', $ticket->{ref}, '--column', 'Not A Real Column!' );
    isnt( $status, 0, 'ticket.move with a malformed column name is refused' );
    like( $said, qr/--column\b/, 'and points at --column, the flag ticket.move actually takes' );
    unlike( $said, qr/--name\b/, 'not --name, which ticket.move does not take at all' );
}

# --- hierarchy.link: --ref is not the answer, because it takes none --------

{
    my ( $status, $said ) = run( 'hierarchy.link', '--ref', $ticket->{ref} );
    isnt( $status, 0, 'hierarchy.link with --ref alone is refused' );
    unlike( $said, qr/--ref\b/, 'not told to supply --ref, which hierarchy.link does not take' );
    like( $said, qr/--parent\b/, 'told about --parent, which it does take' );

    my ( $status2, $said2 ) = run( 'hierarchy.link', '--parent', $epic->{ref} );
    isnt( $status2, 0, 'hierarchy.link with only --parent is refused' );
    like( $said2, qr/--child\b/, 'and told about --child once --parent is supplied' );
}

# --- a message with one true answer needs no per-command entry -------------
#
# assign.list still gets the plain default: no override exists for it, and
# none should be needed.

{
    my ( $status, $said ) = run('assign.list');
    isnt( $status, 0, 'assign.list with nothing is still refused' );
    like( $said, qr/--ref\b/, 'and still says --ref, unaffected by the per-command table' );
}

# --- and the underlying engine message is unchanged -------------------------

{
    my ( undef, $said ) = run( 'ticket.move', '--ref', $ticket->{ref}, '--column', 'Not A Real Column!' );
    like( $said, qr/Invalid column name/, 'the engine still says what is wrong, in its own words' );
}

done_testing();

__END__

=head1 NAME

689-a-flag-named-for-the-wrong-command.t - a refusal names the flag the
raising command actually takes

=head1 DESCRIPTION

TKT-689. C<%SUPPLIED_BY> answered one flag per message, which is wrong when
two commands spell the same concept differently: C<ticket.move>'s "Invalid
column name" wants C<--column>, not the C<--name> that answers for
C<column.add>/C<rename>/C<move>; C<hierarchy.link>'s "Record reference is
required" wants C<--parent>/C<--child>, not C<--ref>, which it does not
take at all. C<Tira::CLI::Usage::_names_the_option> now takes the raising
command and checks a small per-command override table before falling back
to the single-answer default.

=cut
